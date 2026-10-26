import Foundation
import SwiftUI

/// D46: the checkbox of a File Analysis row or block, drawn like the
/// cleanup results' group checkboxes (an outlined square, a filled check in
/// the module color). An item that cannot move shows a lock; clicking it, or
/// an item inside a checked folder, explains instead of checking.
struct FileAnalysisTrashCheckbox: View {
    let state: FileAnalysisTrashSelectionState
    let title: String
    let isBusy: Bool
    let onToggle: () -> Void

    private var systemImage: String {
        switch state {
        case .available: "square"
        case .selected: "checkmark.square.fill"
        case .includedInSelection: "checkmark.square"
        case .blocked: "lock.fill"
        case .checking: "clock"
        }
    }

    private var color: Color {
        switch state {
        case .available: AppDesignTokens.Palette.secondaryText
        case .selected: AppDesignTokens.Palette.storage
        case .includedInSelection: AppDesignTokens.Palette.storage.opacity(0.6)
        case .blocked, .checking: AppDesignTokens.Palette.tertiaryText
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .available: L10n.text("未勾选", "Not checked")
        case .selected: L10n.text("已勾选", "Checked")
        case .includedInSelection: L10n.text("随所选文件夹移走", "Moves with the checked folder")
        case .blocked: L10n.text("不能勾选", "Cannot be checked")
        case .checking: L10n.text("检查中，暂不能勾选", "Checking; cannot be checked yet")
        }
    }

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: systemImage)
                .font(AppDesignTokens.Typography.symbol)
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .disabled(isBusy)
        .help(FileAnalysisTrashPresentation.checkboxHelp(state: state))
        .accessibilityLabel(L10n.text("移到废纸篓：\(title)", "Move to Trash: \(title)"))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(FileAnalysisTrashPresentation.checkboxHelp(state: state))
    }
}

/// Wording shared by the rows, the blocks, the bar and the review (D46).
enum FileAnalysisTrashPresentation {
    /// The bar's line while items wait for `check`.
    static func checkingNotice(_ check: FileAnalysisTrashPendingCheck) -> String {
        switch check {
        case .iCloud:
            L10n.text("正在确认 iCloud 状态…", "Confirming iCloud status…")
        case .volume:
            L10n.text("正在确认卷状态…", "Confirming the volume's status…")
        case .protectedLocations:
            L10n.text("正在核对受保护的位置…", "Checking protected locations…")
        }
    }

    /// What a click on a waiting item says.
    static func checkingClickNotice(_ check: FileAnalysisTrashPendingCheck, title: String) -> String {
        switch check {
        case .iCloud:
            L10n.text("正在确认“\(title)”所在位置是否由 iCloud 保管，请稍候再勾选。",
                      "Still checking whether iCloud keeps “\(title)”; check it again in a moment.")
        case .volume:
            L10n.text("正在确认“\(title)”所在的卷是否只读，请稍候再勾选。",
                      "Still checking whether the volume of “\(title)” is read-only; check it again in a moment.")
        case .protectedLocations:
            L10n.text("正在核对受保护的位置，请稍候再勾选“\(title)”。",
                      "Still checking protected locations; check “\(title)” again in a moment.")
        }
    }

    static func checkboxHelp(state: FileAnalysisTrashSelectionState) -> String {
        switch state {
        case .available:
            L10n.text("勾选后可审阅并移到废纸篓", "Check to review and move to the Trash")
        case .selected:
            L10n.text("已勾选；再点一次取消", "Checked; click again to uncheck")
        case .includedInSelection(let folder):
            L10n.text("在已勾选的“\(folder)”里，会随它一起移走", "Inside the checked “\(folder)”; it moves with it")
        case .blocked(let block, let applications):
            L10n.text("不能移到废纸篓：", "Cannot move to the Trash: ") + block.explanation(naming: applications)
        case .checking(let check):
            checkingExplanation(check)
        }
    }

    /// Review P2-12, r2-fa-followups P1-1: why a box waits before it can be
    /// checked.
    static func checkingExplanation(_ check: FileAnalysisTrashPendingCheck) -> String {
        switch check {
        case .iCloud:
            L10n.text("检查中：正在确认这个位置是否由 iCloud 保管，确认后才能勾选。",
                      "Checking whether iCloud keeps this location; it can be checked once that is known.")
        case .volume:
            L10n.text("检查中：正在确认这个卷是否只读，确认后才能勾选。",
                      "Checking whether this volume is read-only; it can be checked once that is known.")
        case .protectedLocations:
            L10n.text("检查中：正在核对经由链接到达的受保护位置（如邮件、钥匙串和密钥），确认后才能勾选。",
                      "Checking protected locations reached through links (such as Mail, keychains and keys); it can be checked once that is known.")
        }
    }

    /// The short note a row shows after its kind and size.
    static func rowNote(state: FileAnalysisTrashSelectionState) -> String? {
        switch state {
        case .available, .selected: nil
        case .includedInSelection(let folder): L10n.text("随“\(folder)”移走", "Moves with “\(folder)”")
        case .blocked(let block, _): block.shortTitle
        case .checking: L10n.text("检查中", "Checking")
        }
    }

    static func rowNoteLineLimit(state: FileAnalysisTrashSelectionState) -> Int {
        if case .includedInSelection = state { return 2 }
        return 1
    }

    /// Review P2-10: a move that could not start, in people's words.
    static var moveDidNotStart: String {
        L10n.text("没能开始移到废纸篓：后台任务的状态有变化，没有移动任何项目，请再试一次。",
                  "Could not start moving to the Trash: the background task changed, so nothing moved. Try again.")
    }

    /// r2-fa-followups P2-3: only codes; the notice above already says what
    /// happened, also for the coordinator's errors. Main-session ruling
    /// (RULES §5, no internal type names on screen): a system error keeps its
    /// domain and code (`NSCocoaErrorDomain:513`); an error type of this app,
    /// or of the Swift runtime, whose domain is its type name, reads as
    /// 应用内部错误（代码 N）. Receipts keep `UninstallErrorEvidence.codes`.
    static func moveFailureDetail(_ error: Error) -> String {
        let codes = UninstallErrorEvidence.chain(error).map { link in
            isInternalErrorDomain(link.domain)
                ? L10n.text("应用内部错误（代码 \(link.code)）", "Internal error (code \(link.code))")
                : "\(link.domain):\(link.code)"
        }
        return L10n.text("错误域与错误码：", "Error domains and codes: ") + codes.joined(separator: " > ")
    }

    /// A Swift error's domain is its type name: this app's own modules and
    /// the Swift runtime's (`Swift.CancellationError`).
    static func isInternalErrorDomain(_ domain: String) -> Bool {
        internalErrorDomainPrefixes.contains { domain.hasPrefix($0) }
    }

    private static let internalErrorDomainPrefixes = [
        "StorageCleanerMac.", "FanControlShared.", "FileOperationShared.", "MSeriesKernels.",
        "StorageCleanerFileOperationHelper.", "StorageCleanerFanControlHelper.", "Swift.",
    ]

    static func reviewBlockNote(_ block: FileAnalysisTrashBlock, applications: [String] = []) -> String {
        L10n.text("不会处理：", "Will not move: ") + block.explanation(naming: applications)
    }

    /// Review P2-2: the run stopped because a receipt could not be written.
    static var receiptIncompleteNote: String {
        L10n.text("回执未写完，请在“操作记录”中核对：移动中途写入操作记录失败，已停下；已移走的项目可能显示为“结果待核实”。",
                  "The receipt is incomplete; check Operation History. Writing it failed midway, so the move stopped; moved items may show as needing verification.")
    }

    /// D104 G1: what a ready file frees once the Trash is emptied, when
    /// clones or a local snapshot keep noticeably part of it.
    static func reclaimableNote(_ item: FileAnalysisTrashReviewItem) -> String? {
        guard item.isReady else { return nil }
        return CleanupCandidateRowHint.reclaimable(item.reclaimableEstimate, ofSize: item.selection.bytes)?.text
    }

    /// D54 ④: a file with other hard links.
    static var otherHardLinksNote: String {
        L10n.text("另有硬链接，移走后空间不一定释放", "Has other hard links; moving it may free no space")
    }

    static func selectionSummary(count: Int, bytes: Int64) -> String {
        L10n.text("已选 \(ByteFormat.count(count)) 项 · \(ByteFormat.storageString(bytes))",
                  "\(L10n.items(count)) selected · \(ByteFormat.storageString(bytes))")
    }

    static let reviewAction = L10n.text("审阅并移到废纸篓", "Review and Move to Trash")

    static let trashFootnote = L10n.text(
        "移到废纸篓后可在“操作记录”中恢复；清空废纸篓后才会释放空间。",
        "Items moved to the Trash can be restored from Operation History; space is freed when the Trash is emptied."
    )

    static func otherTrashNote(volumes: [String]) -> String {
        let names = volumes.joined(separator: L10n.text("、", ", "))
        return L10n.text(
            "“\(names)”上的项目会移到该卷的废纸篓；“操作记录”会记下这次移动，需要时在访达中从该卷的废纸篓放回。",
            "Items on “\(names)” go to that volume's Trash. Operation History records the move; put them back from that Trash in Finder."
        )
    }

    static func itemDetail(_ selection: FileAnalysisTrashSelection) -> String {
        guard selection.isDirectory else {
            return StorageMapContentCategory.classify(name: selection.title, kind: selection.kind, isDirectory: false).title
        }
        let kind = selection.kind == "package" && !selection.presentsAsFolder
            ? StorageMapContentCategory.classify(name: selection.title, kind: "package", isDirectory: true).title
            : L10n.text("文件夹", "Folder")
        guard let count = selection.itemCount else { return kind }
        return L10n.text("\(kind) · 含 \(ByteFormat.count(count)) 项", "\(kind) · \(L10n.items(count)) inside")
    }
}

/// The bar under the map: what is checked and the review button; after a
/// move, what moved and what was kept and why.
struct FileAnalysisTrashBar: View {
    @ObservedObject var workspace: LargeFilesStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            // One row while items are checked, so a short window keeps the
            // map; how to restore is said in the review and after the move.
            if !workspace.trashSelections.isEmpty {
                selectionRow
            } else if let outcome = workspace.trashOutcome {
                outcomeRows(outcome)
            }
            if let notice = workspace.trashRefinementNotice {
                Text(notice)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            if workspace.trashPutBackCount > 0 {
                Text(L10n.text("已从“操作记录”放回 \(ByteFormat.count(workspace.trashPutBackCount)) 项，已重新计入。",
                              "\(L10n.items(workspace.trashPutBackCount)) put back from Operation History are counted again."))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.success)
            }
            if let notice = workspace.trashNotice, workspace.trashPhase == .idle {
                HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.medium) {
                    Text(notice)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Nothing else in the bar to close it with.
                    if workspace.trashSelections.isEmpty, workspace.trashOutcome == nil {
                        Spacer(minLength: AppDesignTokens.Spacing.small)
                        Button(L10n.text("好", "OK")) {
                            workspace.dismissTrashOutcome()
                        }
                        .appButtonChrome(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, AppDesignTokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 0, tint: AppDesignTokens.Palette.storage, elevated: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("移到废纸篓", "Move to Trash"))
    }

    private var selectionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppDesignTokens.Spacing.medium) {
                selectionSummary
                Spacer(minLength: AppDesignTokens.Spacing.small)
                actions
            }
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                selectionSummary
                actions
            }
        }
    }

    private var selectionSummary: some View {
        Text(FileAnalysisTrashPresentation.selectionSummary(
            count: workspace.trashSelections.count, bytes: workspace.selectedTrashBytes
        ))
        .monospacedDigit()
        .font(AppDesignTokens.Typography.compactLabelEmphasis)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var actions: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            Button(L10n.text("清除", "Clear")) {
                workspace.clearTrashSelection()
            }
            .appButtonChrome(.secondary)
            .disabled(workspace.trashPhase != .idle)

            Button {
                workspace.requestTrashReview()
            } label: {
                if workspace.trashPhase == .preparingReview {
                    HStack(spacing: AppDesignTokens.Spacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.text("正在核对…", "Checking…"))
                    }
                } else {
                    Text(FileAnalysisTrashPresentation.reviewAction)
                }
            }
            .appButtonChrome(.primary)
            .tint(AppDesignTokens.Palette.destructive)
            .disabled(!workspace.canReviewTrash)
            .help(FileAnalysisTrashPresentation.trashFootnote)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func outcomeRows(_ outcome: FileAnalysisTrashOutcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.medium) {
            // Review P2-2: a receipt behind what moved is not a plain success.
            let warns = outcome.movedPaths.isEmpty || outcome.receiptIncomplete
            Group {
                if warns {
                    Label(outcomeTitle(outcome), systemImage: "exclamationmark.triangle.fill")
                } else {
                    Text(outcomeTitle(outcome))
                }
            }
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(warns ? AppDesignTokens.Palette.warning : AppDesignTokens.Palette.success)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AppDesignTokens.Spacing.small)
            Button(L10n.text("好", "OK")) {
                workspace.dismissTrashOutcome()
            }
            .appButtonChrome(.secondary)
        }
        // D93: completed / skipped / failed / needs verification; moved is not freed.
        // The incomplete-receipt note below is not repeated inside the tally (P2-7).
        OperationCompletionTallyView(tally: OperationCompletionTally(fileAnalysis: outcome), showsEntryDetails: false,
                                     showsReceiptNote: false)
        if outcome.receiptIncomplete {
            // Review P2-2: not just "moved"; the receipt is behind.
            Label(FileAnalysisTrashPresentation.receiptIncompleteNote, systemImage: "exclamationmark.triangle.fill")
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if !outcome.movedPaths.isEmpty {
            Text(outcomeRestoreNote(outcome))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(outcome.skipped.prefix(3)) { skipped in
            Label {
                Text(L10n.text("“\(skipped.title)”：\(skipped.reason)", "“\(skipped.title)”: \(skipped.reason)"))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(AppDesignTokens.Palette.warning)
            }
            .font(AppDesignTokens.Typography.metadata)
            .help(skipped.path)
        }
        if outcome.skipped.count > 3 {
            Text(L10n.text("另有 \(outcome.skipped.count - 3) 项未移动，详见“操作记录”。",
                           "\(L10n.items(outcome.skipped.count - 3)) more not moved; see Operation History."))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
        }
    }

    private func outcomeTitle(_ outcome: FileAnalysisTrashOutcome) -> String {
        if outcome.receiptUnavailable {
            return L10n.text("无法写入操作记录；为了能恢复，没有移动任何项目。",
                             "Operation History could not be written, so nothing was moved (to keep it restorable).")
        }
        if outcome.movedPaths.isEmpty {
            return outcome.cancelled
                ? L10n.text("已停止，没有移动任何项目。", "Stopped; nothing was moved.")
                : L10n.text("没有移动任何项目。", "Nothing was moved.")
        }
        let moved = L10n.text(
            "已移到废纸篓 \(ByteFormat.count(outcome.movedPaths.count)) 项 · \(ByteFormat.storageString(outcome.movedBytes))",
            "Moved \(L10n.items(outcome.movedPaths.count)) to the Trash · \(ByteFormat.storageString(outcome.movedBytes))"
        )
        guard !outcome.skipped.isEmpty else { return moved }
        return moved + L10n.text("；\(ByteFormat.count(outcome.skipped.count)) 项未移动", "; \(ByteFormat.count(outcome.skipped.count)) not moved")
    }

    private func outcomeRestoreNote(_ outcome: FileAnalysisTrashOutcome) -> String {
        if !outcome.externalVolumeNames.isEmpty {
            return FileAnalysisTrashPresentation.otherTrashNote(volumes: outcome.externalVolumeNames)
        }
        if outcome.notRestorableHereCount > 0 {
            return L10n.text(
                "其中 \(ByteFormat.count(outcome.notRestorableHereCount)) 项的结果需要核实，请在“操作记录”中刷新后查看。",
                "\(L10n.items(outcome.notRestorableHereCount)) need checking; refresh Operation History to review them."
            )
        }
        return FileAnalysisTrashPresentation.trashFootnote
    }
}

/// The review before anything moves (D46, like Space Lens's "Review and
/// Remove"): every checked item with its path and size, whether it can
/// move, the total, and what happens next. The move runs from here and
/// shows its progress here.
struct FileAnalysisTrashReviewSheet: View {
    @Environment(\.moduleTheme) private var theme
    @ObservedObject var workspace: LargeFilesStore
    let review: FileAnalysisTrashReview

    /// D93: probed once when the review opens; nothing is moved by the probe.
    @State private var permission: OperationPermissionCoverage = .unknown

    private var isMoving: Bool { workspace.trashPhase == .moving }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            header
            // D93: the six fixed confirmation fields; the list below is the item list.
            OperationConfirmationFactsView(facts: .fileAnalysis(review, permission: permission), showsItemList: false)
            itemList
            notes
            if isMoving, let progress = workspace.trashProgress {
                progressView(progress)
            }
            if let notice = workspace.trashNotice, workspace.trashPhase == .reviewing {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                // P2-7：详情只展示中文说明或错误域与代码。
                if let detail = workspace.trashNoticeDetail {
                    DisclosureGroup(L10n.text("详情", "Details")) {
                        Text(detail)
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(AppDesignTokens.Typography.metadata)
                }
            }
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 520)
        .background(ModuleBackground(theme: theme))
        .foregroundStyle(theme.primaryText)
        .interactiveDismissDisabled(isMoving)
        .task { permission = .from(ScanReadinessService.fullDiskAccessState()) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("审阅后移到废纸篓", "Review Before Moving to the Trash"))
                    .font(AppDesignTokens.Typography.sectionTitle)
                Text(L10n.text(
                    "\(ByteFormat.count(review.readyItems.count)) 项可以移到废纸篓 · 合计 \(ByteFormat.storageString(review.readyBytes))",
                    "\(L10n.items(review.readyItems.count)) can move · \(ByteFormat.storageString(review.readyBytes)) in total"
                ))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                if review.blockedCount > 0 {
                    Text(L10n.text("另有 \(ByteFormat.count(review.blockedCount)) 项不会处理，原因见下方。",
                                   "\(L10n.items(review.blockedCount)) will not be handled; see why below."))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var itemList: some View {
        let rows = VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            ForEach(review.items) { item in
                FileAnalysisTrashReviewRow(item: item, unknownApplications: review.unknownRunningApplicationNames)
            }
        }
        Group {
            if review.items.count <= 4 {
                rows
            } else {
                ScrollView { rows }
                    .frame(height: 300)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("要移到废纸篓的项目", "Items to move to the Trash"))
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
            Text(L10n.text(
                "移前逐项复核，变化则跳过；操作记录可恢复，清空废纸篓后释放空间",
                "Recheck before moving; skip changed items; restore from Operation History; empty Trash to free space"
            ))
            if !review.externalVolumeNames.isEmpty {
                Text(FileAnalysisTrashPresentation.otherTrashNote(volumes: review.externalVolumeNames))
                    .foregroundStyle(AppDesignTokens.Palette.warning)
            }
        }
        .font(AppDesignTokens.Typography.metadata)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func progressView(_ progress: FileAnalysisTrashProgress) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
            ProgressView(value: Double(progress.processed), total: Double(max(1, progress.total)))
            Text(L10n.text("正在核对并移动 \(progress.processed) / \(progress.total)",
                           "Checking and moving \(progress.processed) / \(progress.total)"))
                .font(AppDesignTokens.Typography.metadata)
                .monospacedDigit()
            if let title = progress.verifyingTitle {
                Text(L10n.text("正在与分析结果比对“\(title)”（已读 \(ByteFormat.count(progress.verifiedItemCount)) 项）",
                               "Comparing “\(title)” with the analysis (\(ByteFormat.count(progress.verifiedItemCount)) items read)"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var buttons: some View {
        HStack {
            if isMoving {
                Button(L10n.text("停止", "Stop")) {
                    workspace.stopTrashMove()
                }
                .appButtonChrome(.secondary)
            } else {
                Button(L10n.text("取消", "Cancel")) {
                    workspace.cancelTrashReview()
                }
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
            Button {
                workspace.confirmTrash()
            } label: {
                Text(L10n.text("移到废纸篓（\(ByteFormat.count(review.readyItems.count)) 项）",
                                "Move \(L10n.items(review.readyItems.count)) to the Trash"))
            }
            .appButtonChrome(.primary)
            .tint(AppDesignTokens.Palette.destructive)
            .keyboardShortcut(.defaultAction)
            .disabled(review.readyItems.isEmpty || isMoving)
        }
    }
}

private struct FileAnalysisTrashReviewRow: View {
    let item: FileAnalysisTrashReviewItem
    /// P2-2: named when a folder cannot move whole because of them.
    let unknownApplications: [String]

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Text(item.selection.title)
                        .font(AppDesignTokens.Typography.compactLabelEmphasis)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: AppDesignTokens.Spacing.small)
                    Text(ByteFormat.storageString(item.selection.bytes))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                Text(item.selection.path)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.selection.path)
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Text(FileAnalysisTrashPresentation.itemDetail(item.selection))
                        .foregroundStyle(.secondary)
                    statusLabel
                }
                .font(AppDesignTokens.Typography.metadata)
                if case .blocked(let block) = item.status {
                    Text(block.explanation(naming: unknownApplications))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.hasOtherHardLinks {
                    // D54 ④.
                    Text(FileAnalysisTrashPresentation.otherHardLinksNote)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reclaimable = FileAnalysisTrashPresentation.reclaimableNote(item) {
                    // D104 G1: clones or a local snapshot keep part of it.
                    Text(reclaimable)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch item.status {
        case .ready:
            Label(L10n.text("可以移到废纸篓", "Ready to move"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(AppDesignTokens.Palette.success)
        case .blocked(let block):
            Label(FileAnalysisTrashPresentation.reviewBlockNote(block, applications: unknownApplications),
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .help(block.explanation(naming: unknownApplications))
        }
    }
}
