import AppKit
import SwiftUI

struct UninstallPreviewSheet: View {
    @ObservedObject var store: ScanStore
    let app: InstalledAppItem
    var embedded: Bool = false
    @State private var showReceipts = false
    @State private var confirmRestore = false
    private var selectablePaths: Set<String> { UninstallPresentation.selectablePaths(app) }
    private var isProcessing: Bool { store.isUninstallingApp }
    private var result: UninstallReviewResult? { store.uninstallResult }
    private var residual: Bool { store.residualUninstallReport != nil }
    private var selected: [InstalledAppRelatedItem] { app.relatedItems.filter { store.uninstallSelectedPaths.contains($0.path) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                UninstallPreviewAppIcon(path: app.path)
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.name).font(AppDesignTokens.Typography.inlineTitle).fixedSize(horizontal: false, vertical: true)
                    Text(result != nil ? (residual ? L10n.text("残留清理结果", "Leftover Cleanup Result") : L10n.text("卸载结果", "Uninstall Result")) : residual ? L10n.text("残留文件", "Leftover Files") : app.versionDisplay)
                        .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isProcessing || store.isPreparingUninstall { ProgressView().controlSize(.small) }
            }.padding(16)
            AppSeparator()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let review = result ?? store.uninstallProgress { resultContent(review.display) }
                    else {
                        if !residual {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L10n.text("应用本体", "Application")).fontWeight(.medium)
                                    pathLabel(app.path)
                                }
                                Spacer(minLength: 4)
                                Text(ByteFormat.string(app.sizeBytes)).monospacedDigit()
                            }.padding(12).background(AppAppearanceColors.secondarySurface, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if store.isPreparingUninstall {
                            Text(L10n.text("正在检查关联文件…", "Checking related files…"))
                                .foregroundStyle(.secondary)
                        } else {
                            fileGroup(verified: true)
                            fileGroup(verified: false)
                            if app.relatedItems.isEmpty {
                                Text(L10n.text("未发现关联文件", "No related files found"))
                                    .foregroundStyle(.secondary).padding(.vertical, 12)
                            }
                        }
                        Text(L10n.text("所选数据会一并移入废纸篓。驱动、扩展和订阅可能需另行处理。",
                            "Selected data also moves to Trash. Drivers, extensions and subscriptions may require separate action."))
                            .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
                        // D93: the six fixed confirmation fields; a running app is named here, before Uninstall is clicked.
                        if !store.isPreparingUninstall {
                            OperationConfirmationFactsView(facts: confirmationFacts, showsItemList: false)
                        }
                    }
                    if let recovery = store.operationRecoveryResult { Text(recovery.resultMessage).foregroundStyle(.secondary) }
                }.font(AppDesignTokens.Typography.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: embedded ? 0 : 160, maxHeight: embedded ? .infinity : 480)
            AppSeparator()
            footer.padding(16)
        }
        .frame(minWidth: embedded ? 0 : 360, idealWidth: 620, maxWidth: embedded ? .infinity : 760)
        .background(AppAppearanceColors.panel)
        .interactiveDismissDisabled(isProcessing || store.isRestoringRecordedOperation)
        .sheet(isPresented: $showReceipts) {
            ReversibleOperationsView(store: store, resumeUninstall: { store.prepareResidualUninstall($0) })
        }
        .confirmationDialog(L10n.text("恢复已移走的文件？", "Restore moved files?"), isPresented: $confirmRestore) {
            // The original receipt and any retry receipts, not only the latest run.
            Button(L10n.text("恢复", "Restore")) { store.restoreUninstallResult() }
        } message: {
            Text(L10n.text("恢复到原位置；同名文件不会覆盖。", "Restore to original locations without overwriting existing files."))
        }
    }

    private var confirmationFacts: OperationConfirmationFacts {
        .uninstall(app: app, selected: selected, residual: residual,
                   runningAppNames: Self.runningNames(app),
                   permission: .from(store.scanReadinessSummary))
    }

    /// The app is checked again when the uninstall runs; this only says so up front.
    private static func runningNames(_ app: InstalledAppItem) -> [String] {
        guard !app.bundleIdentifier.isEmpty,
              !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
        else { return [] }
        return [app.name]
    }

    private func pathLabel(_ path: String) -> some View {
        UninstallPathLabel(path: path)
    }

    @ViewBuilder private func fileGroup(verified: Bool) -> some View {
        let items = app.relatedItems.filter { selectablePaths.contains($0.path) == verified }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(verified ? L10n.text("关联文件", "Related Files") : L10n.text("保留文件", "Kept Files"))
                        .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    Text("\(items.count)").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    // D87: high-value data (browser profiles, Docker data) is
                    // never part of the bulk selection; it is ticked one by one.
                    let bulk = items.filter { UninstallPresentation.bulkSelectablePaths(app).contains($0.path) }
                    if verified && !bulk.isEmpty {
                        let all = bulk.allSatisfy { store.uninstallSelectedPaths.contains($0.path) }
                        Button(all ? L10n.text("取消全选", "Deselect All") : L10n.text("全选已核实项", "Select All Verified")) {
                            let paths = Set(bulk.map(\.path))
                            if all { store.uninstallSelectedPaths.subtract(paths) }
                            else { store.uninstallSelectedPaths.formUnion(paths) }
                        }.appButtonChrome(.tertiary).foregroundStyle(AppDesignTokens.Palette.information)
                    }
                }
                if verified {
                    // D1: unchecked by default; only the application itself is preselected.
                    // In leftover mode the app is already in Trash.
                    Text(residual
                         ? L10n.text("包含设置和本地数据，默认保留；勾选的项目会移入废纸篓。",
                                     "Includes settings and local data, kept by default; checked items move to Trash.")
                         : L10n.text("包含设置和本地数据，默认保留；勾选后才会随应用移入废纸篓。",
                                     "Includes settings and local data, kept by default; checked items move to Trash with the app."))
                        .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
                }
                ForEach(items) { relatedRow($0, selectable: verified) }
            }
        }
    }
    private func relatedRow(_ item: InstalledAppRelatedItem, selectable: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if selectable {
                Toggle(isOn: Binding(get: { store.uninstallSelectedPaths.contains(item.path) }, set: {
                    if $0 { store.uninstallSelectedPaths.insert(item.path) }
                    else { store.uninstallSelectedPaths.remove(item.path) }
                })) { Text(UninstallPresentation.category(item.path)) }.toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(UninstallPresentation.category(item.path) + " " + item.path)
            } else { Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 16) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(UninstallPresentation.category(item.path)).fontWeight(.medium)
                    Spacer(minLength: 6)
                    Text(item.sizeIsKnown ? ByteFormat.string(item.sizeBytes) : L10n.text("大小未知", "Unknown size"))
                        .foregroundStyle(.secondary).monospacedDigit().fixedSize()
                }
                pathLabel(item.path)
                if let highValue = UninstallVendorRules.highValueData(path: item.path) {
                    Label(highValue.title, systemImage: "exclamationmark.triangle")
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                }
                if !selectable {
                    HStack(alignment: .top) {
                        Text(item.ownershipBlockReason.title).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button(L10n.text("查看", "Reveal")) { store.reveal(item.path) }.appButtonChrome(.tertiary)
                            .foregroundStyle(AppDesignTokens.Palette.information).help(L10n.text("在访达中显示", "Show in Finder"))
                    }.font(AppDesignTokens.Typography.metadata)
                }
            }
        }.padding(12).background(AppAppearanceColors.secondarySurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if result == nil && !isProcessing {
                let count = selected.count + (residual ? 0 : 1)
                let knownBytes = selected.filter(\.sizeIsKnown).reduce(Int64(0)) { $0 + $1.sizeBytes } + (residual ? 0 : app.sizeBytes)
                HStack {
                    Text(L10n.text("已选 \(count) 项", "\(count) selected")).fontWeight(.medium)
                    Spacer()
                    Text(ByteFormat.string(knownBytes) + (selected.contains(where: { !$0.sizeIsKnown }) ? " + ?" : "")).monospacedDigit()
                }
                Text(L10n.text("移入废纸篓，可恢复；清空前不释放空间。", "Recoverable in Trash; space is freed only when Trash is emptied."))
                    .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }.font(AppDesignTokens.Typography.secondary)
    }
    @ViewBuilder private var actions: some View {
        Button(isProcessing ? L10n.text("取消", "Cancel") : L10n.text("关闭", "Close"), role: .cancel) { store.cancelUninstall() }
            .keyboardShortcut(.cancelAction).disabled(store.isCancellingUninstall || store.isRestoringRecordedOperation)
        if let result {
            Button(L10n.text("恢复文件", "Restore Files")) { confirmRestore = true }
                .disabled(!result.canRestore || store.isRestoringRecordedOperation)
            Menu(L10n.text("更多", "More")) {
                Button(L10n.text("查看记录", "View Record")) { showReceipts = true }
                // The saved receipt that moved the app, never the merged display.
                if let receipt = result.residualReceipt {
                    Button(L10n.text("检查残留", "Check Leftovers")) { store.prepareResidualUninstall(receipt) }
                }
            }
            if store.canRetryUninstall {
                Button(L10n.text("重试未完成项", "Retry Unfinished")) { store.confirmUninstall(retrying: true) }
                    .appButtonChrome(.primary).disabled(isProcessing || store.isRestoringRecordedOperation)
            }
        } else {
            Button(role: .destructive) { store.confirmUninstall(selectedPaths: store.uninstallSelectedPaths) } label: {
                Text(store.isCancellingUninstall ? L10n.text("正在收尾…", "Finishing…") : isProcessing ? L10n.text("正在处理…", "Processing…") : residual ? L10n.text("清理所选文件", "Clean Selected Files") : L10n.text("卸载并移入废纸篓", "Uninstall to Trash"))
            }.appButtonChrome(.primary).tint(AppDesignTokens.Palette.destructive)
                .disabled(store.isPreparingUninstall || !store.canRequestUninstall(app) || isProcessing || (residual && selected.isEmpty))
        }
    }

    private func resultContent(_ report: CleanReport) -> some View {
        let result = OperationResultPresentation(report: report, processing: isProcessing,
            draining: store.isCancellingUninstall)
        let retained = UninstallPresentation.retainedItems(app, report: report)
        return VStack(alignment: .leading, spacing: 12) {
            Label(result.title, systemImage: result.systemImage)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
            Text(result.summary).foregroundStyle(.secondary)
            // D93: four groups; the app moved to Trash is not counted as freed space.
            // A row refused while the app is running reads "Skipped (the app is running)",
            // as the confirmation said; the receipt warning is shown below (P2-3, P2-7).
            OperationCompletionTallyView(tally: OperationCompletionTally(
                uninstall: report, app: app, appIsRunning: !Self.runningNames(app).isEmpty
            ), showsEntryDetails: false, showsReceiptNote: false)
            ForEach(report.items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.sourcePath == app.path ? L10n.text("应用本体", "Application") : UninstallPresentation.category(item.sourcePath)).fontWeight(.medium)
                    Text(itemOutcomeText(item, report: report)).fixedSize(horizontal: false, vertical: true)
                    pathLabel(item.sourcePath)
                    if case .failed(let failure) = item.outcome, !isProcessing,
                       let reason = UninstallFailureReason(failure) {
                        failureActions(reason, path: item.sourcePath)
                    }
                    if case .failed(let failure) = item.outcome, let detail = failure.detailCode, detail != "move-in-flight" {
                        DisclosureGroup(L10n.text("技术详情", "Technical Details")) {
                            Text(detail).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppAppearanceColors.secondarySurface, in: RoundedRectangle(cornerRadius: 10))
            }
            if !retained.isEmpty {
                Text(L10n.text("已保留 \(retained.count) 项", "\(retained.count) items kept")).fontWeight(.medium)
                ForEach(retained) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(UninstallPresentation.category(item.path))
                        Text(selectablePaths.contains(item.path) ? L10n.text("未勾选，已保留", "Not selected; kept") : item.ownershipBlockReason.title).foregroundStyle(.secondary)
                        pathLabel(item.path)
                    }
                }
            }
            if report.persistenceFailure != nil {
                Label(L10n.text("回执保存失败，请勿重复操作。", "Receipt saving failed. Do not repeat the operation."), systemImage: "exclamationmark.triangle")
            }
            if store.isCancellingUninstall { Text(L10n.text("等待系统操作结束并保存结果…", "Waiting for the system operation and saving results…")) }
        }
    }
    /// Where the user can act when no password was requested for the app.
    @ViewBuilder private func failureActions(_ reason: UninstallFailureReason, path: String) -> some View {
        if [.systemRefused, .unsupportedLocation, .locked].contains(reason) {
            HStack(spacing: 8) {
                if reason == .systemRefused {
                    Button(L10n.text("打开系统设置", "Open System Settings")) { _ = CleanupService.openAppManagementSettings() }
                        .appButtonChrome(.tertiary).foregroundStyle(AppDesignTokens.Palette.information)
                }
                Button(L10n.text("在访达中显示", "Show in Finder")) { store.reveal(path) }
                    .appButtonChrome(.tertiary).foregroundStyle(AppDesignTokens.Palette.information)
            }.font(AppDesignTokens.Typography.metadata)
        }
    }
    private func itemOutcomeText(_ item: CleanReportItem, report: CleanReport) -> String {
        guard let recovery = (report.recoveryAttempts ?? []).flatMap(\.items)
            .last(where: { $0.originalPath == item.sourcePath }) else { return outcomeText(item.outcome) }
        switch recovery.outcome {
        case .restored: return L10n.text("已恢复到原位置", "Restored to the original location")
        case .conflict: return L10n.text("恢复遇到同名文件，未覆盖", "Restore conflict; existing file retained")
        case .outcomeUnknown: return L10n.text("恢复结果待核实，勿重复操作", "Restore unconfirmed; do not repeat")
        case .notProcessed: return L10n.text("恢复未执行", "Restore not run")
        case .missing: return L10n.text("恢复来源不存在", "Recovery source is missing")
        case .identityChanged: return L10n.text("恢复来源身份已变化", "Recovery source identity changed")
        case .unsafePath: return L10n.text("恢复路径检查未通过", "Recovery path validation failed")
        case .failed: return L10n.text("恢复失败，请查看回执", "Restore failed; review the receipt")
        }
    }
    private func outcomeText(_ outcome: CleanItemOutcome) -> String {
        switch outcome {
        case .moved(let receipt): receipt.isRestorable ? L10n.text("已移入废纸篓，可恢复", "Moved to Trash; recoverable") : L10n.text("移动已报告，身份待核实", "Move reported; identity unverified")
        case .notProcessed: L10n.text("未执行，原文件保留", "Not run; original retained")
        case .skipped: L10n.text("已跳过", "Skipped")
        case .failed(let failure):
            failureText(failure)
        case .deleted: L10n.text("已永久删除", "Permanently deleted")
        }
    }
    private func failureText(_ failure: CleanFailure) -> String {
        let code = failure.detailCode ?? "unknown"
        if code == "move-in-flight" { return L10n.text("系统处理中…", "System operation in progress…") }
        switch UninstallFailureReason(failure) {
        case .systemRefused?:
            // Do not assert a cause: App Management is one possibility only.
            return L10n.text("系统拒绝移动此应用；文件权限不是原因，因此未请求管理员密码。如果本应用未在“应用管理”中获得允许，请在系统设置 → 隐私与安全性 → 应用管理中允许后重试。原应用保留在原位。",
                "macOS refused to move this app. File permissions are not the cause, so no administrator password was requested. If App Management is turned off for this app, allow it in System Settings → Privacy & Security → App Management, then retry. The original remains in place.")
        case .unsupportedLocation?:
            return L10n.text("需要管理员权限，但授权移动只支持直接放在“应用程序”文件夹或个人“应用程序”文件夹中的应用，因此未请求密码。请在访达中手动移到废纸篓；访达中的操作不会记入本应用的回执。原应用保留在原位。",
                "Administrator rights are needed, but authorized moves only support apps placed directly in the Applications folder or your personal Applications folder, so no password was requested. Move it to Trash in Finder; Finder actions are not recorded in this app's receipts. The original remains in place.")
        case .protectedApp?:
            return L10n.text("授权移动不支持此应用（Apple 自带应用、本应用自身、缺少标识或受系统保护的应用），因此未请求密码。原应用保留在原位。",
                "Authorized moves do not support this app (Apple's apps, this app itself, apps without an identifier, or system-protected apps), so no password was requested. The original remains in place.")
        case .locked?:
            return L10n.text("应用已锁定，无法移动，因此未请求密码。请在访达中选中它，在“显示简介”中取消“已锁定”后重试。原应用保留在原位。",
                "The app is locked, so it cannot be moved and no password was requested. In Finder, select it, open Get Info and turn off Locked, then retry. The original remains in place.")
        case .changedSinceScan?:
            return L10n.text("应用或文件在扫描后已变化，或应用仍在运行，未移动。请退出该应用，再从列表重新选择它。",
                "The app or file changed after the scan, or the app is still running. Nothing was moved. Quit the app, then select it again in the list.")
        case .applicationNotConfirmed?:
            return L10n.text("未能确认应用本体已在废纸篓，关联文件未处理。", "The app could not be confirmed in Trash, so related files were not processed.")
        case .missing?:
            return L10n.text("项目已不存在，未移动。", "The item no longer exists; nothing was moved.")
        case .interrupted?:
            return L10n.text("任务被中断，未移动；可以重试。", "The task was interrupted before the move; you can retry.")
        case .refused?:
            return L10n.text("系统拒绝将其移入废纸篓，原文件保留在原位。", "macOS refused to move it to Trash; the original remains in place.")
        case .authorizationIncomplete?, .helperUnavailable?, .other?, nil: break
        }
        if code.contains("approval-required") {
            return L10n.text("尚未获批：请在系统设置 → 通用 → 登录项与扩展中允许文件操作辅助程序，然后重试。原文件保留。",
                "Approval required: allow the file-operation helper in System Settings → General → Login Items & Extensions, then retry. The original is retained.")
        }
        if code.contains("helper-unavailable") {
            return L10n.text("授权辅助程序缺失或签名不匹配，未执行授权移动。原文件保留。", "The authorization helper is missing or its signature does not match. No authorized move was performed; the original is retained.")
        }
        if code.contains("FileOperationHelper.fileMove") {
            return L10n.text("管理员授权已通过，但移动文件被系统拒绝。请检查应用管理、只读卷或文件保护；文件未移动。", "Administrator authorization succeeded, but the system refused the file move. Check App Management, read-only volumes or file protection. The file was not moved.")
        }
        if code.contains("FileOperationHelper.") {
            return L10n.text("辅助程序未能验证此请求的授权，未移动文件。请重试并保留以下诊断信息。", "The helper could not validate authorization for this request. No file was moved. Retry and retain these diagnostics.")
        }
        if code.contains("authorization-cancelled") {
            return L10n.text("已取消系统授权，原文件保留。", "System authorization was cancelled. The original is retained.")
        }
        if code.contains("helper-registration") {
            return L10n.text("文件操作辅助程序更新或注册失败，原文件保留。", "The file-operation helper could not be updated or registered. The original is retained.")
        }
        if code.contains("authorization-failed") {
            return L10n.text("系统授权流程出错，未执行授权移动。", "The system authorization flow failed. No authorized move was performed.")
        }
        if code.contains("authorization-denied") {
            return L10n.text("系统授权未完成或被拒绝；请检查管理员授权、应用管理和文件权限。", "System authorization was not completed or was denied. Check administrator approval, App Management and file permissions.")
        }
        if failure.code == .moveOutcomeUnknown {
            return L10n.text("结果待核实，请保留回执，勿重复操作。", "Outcome unconfirmed. Keep the receipt and do not repeat this operation.")
        }
        return L10n.text("文件未移动，请查看技术详情。", "File not moved. See technical details.")
    }

}

/// Let selectable text expose its native label. Overriding that label on
/// macOS 27 can recurse through SwiftUI/AppKit AX role resolution.
struct UninstallPathLabel: View {
    let path: String
    var body: some View {
        Text(UninstallPresentation.displayPath(path)).font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            .textSelection(.enabled).help(path)
    }
}
