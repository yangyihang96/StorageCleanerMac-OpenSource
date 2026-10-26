import SwiftUI

extension CareStudioModule {
    /// The module of the junk flow that is scanning, cleaning or reporting.
    static func junkFlow(route: ReviewFilter?) -> CareStudioModule {
        switch route {
        case .green: .cleanup
        case .devCaches: .devTools
        default: .smartScan
        }
    }
}

/// One row of the cleaning list: a junk group of the plan and how far the
/// executor has got in it.
struct CareStudioCleaningTask: Identifiable, Equatable {
    enum State: Equatable { case waiting, working, done }
    let id: String
    let title: String
    let systemImage: String
    let processed: Int
    let total: Int
    let bytes: Int64
    let state: State

    /// CleanMyMac lists one task per category while it cleans
    /// (`CleanItemsListView`, `分报告/cleanmymac.md` §5). The executor walks
    /// the plan in order (`SafeCleanupExecutor`), so its first `processed`
    /// items are the finished ones.
    static func make(planItems: [CleanPlanItem], progress: CleanupExecutionProgress?,
                     isCancelling: Bool) -> [CareStudioCleaningTask] {
        let processed = progress.map { min($0.processedItemCount, planItems.count) } ?? 0
        var order: [CareJunkGroup] = []
        var totals: [CareJunkGroup: (total: Int, done: Int, bytes: Int64, hasCurrent: Bool)] = [:]
        for (index, item) in planItems.enumerated() {
            let group = CareJunkGroup.group(ruleID: item.ruleID)
            if totals[group] == nil {
                order.append(group)
                totals[group] = (0, 0, 0, false)
            }
            totals[group]!.total += 1
            totals[group]!.bytes = CleanupByteCount.sum([totals[group]!.bytes, item.estimatedSizeBytes])
            if index < processed { totals[group]!.done += 1 }
            if index == processed, progress != nil, !isCancelling { totals[group]!.hasCurrent = true }
        }
        return order.compactMap { group in
            guard let entry = totals[group] else { return nil }
            let state: State = entry.done == entry.total ? .done : (entry.hasCurrent ? .working : .waiting)
            return CareStudioCleaningTask(id: group.rawValue, title: group.title, systemImage: group.systemImage,
                                          processed: entry.done, total: entry.total, bytes: entry.bytes, state: state)
        }
    }
}

/// The task list of the cleaning page: one row per group with its mark,
/// what it holds and whether it waits, runs or is done.
struct CareStudioCleaningTaskList: View {
    let module: CareStudioModule
    let tasks: [CareStudioCleaningTask]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(tasks) { task in
                HStack(spacing: 12) {
                    CareStudioGlyph(module: module, systemImage: task.systemImage, side: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(task.state == .waiting ? CareStudioInk.secondary : CareStudioInk.primary)
                        Text(detail(task))
                            .font(.system(size: 11))
                            .foregroundStyle(CareStudioInk.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    mark(task.state)
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                if task.id != tasks.last?.id {
                    Rectangle().fill(CareStudioInk.hairline).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
            .fill(CareStudioInk.tileFill))
        .overlay(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
            .strokeBorder(CareStudioInk.hairline, lineWidth: 1))
#if DEBUG
        .layoutProbe("careStudio.cleaning.tasks")
#endif
    }

    private func detail(_ task: CareStudioCleaningTask) -> String {
        let size = ByteFormat.storageString(task.bytes)
        switch task.state {
        case .waiting:
            return L10n.text("正在等待… · \(ByteFormat.count(task.total)) 项 · \(size)", "Waiting… · \(ByteFormat.count(task.total)) items · \(size)")
        case .working:
            return L10n.text("正在处理 \(ByteFormat.count(task.processed)) / \(ByteFormat.count(task.total)) 项 · \(size)",
                             "Processing \(ByteFormat.count(task.processed)) of \(ByteFormat.count(task.total)) · \(size)")
        case .done:
            return L10n.text("已处理 \(ByteFormat.count(task.total)) 项 · \(size)", "\(ByteFormat.count(task.total)) items processed · \(size)")
        }
    }

    @ViewBuilder
    private func mark(_ state: CareStudioCleaningTask.State) -> some View {
        switch state {
        case .waiting:
            Circle().strokeBorder(CareStudioInk.tertiary, lineWidth: 1.4).frame(width: 16, height: 16)
        case .working:
            CareStudioSpinningArc(diameter: 16, lineWidth: 2)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(CareStudioInk.primary)
        }
    }
}

/// Cleaning: the running page with the cleanup counts as its categories
/// (CleanMyMac rocks the picture and rings Stop while it removes items).
struct CareStudioCleaningPage<Stages: View>: View {
    let module: CareStudioModule
    let title: String
    let detail: String
    let progress: CleanupExecutionProgress?
    /// The items of the plan being executed; their groups become the task list.
    var planItems: [CleanPlanItem] = []
    var isCancelling = false
    var onCancel: (() -> Void)?
    @ViewBuilder var stages: Stages

    private var tasks: [CareStudioCleaningTask] {
        CareStudioCleaningTask.make(planItems: planItems, progress: progress, isCancelling: isCancelling)
    }

    private var fraction: CareStudioActionButton.Progress {
        guard let progress, progress.totalItemCount > 0 else { return .indeterminate }
        return .fraction(Double(progress.processedItemCount) / Double(progress.totalItemCount))
    }

    private var counts: [CareStudioLiveCategory] {
        guard let progress else { return [] }
        var items = [
            CareStudioLiveCategory(id: "moved", title: L10n.text("已移到废纸篓 \(ByteFormat.count(progress.movedItemCount))", "Moved \(ByteFormat.count(progress.movedItemCount))"),
                                   systemImage: "trash", state: progress.movedItemCount > 0 ? .found : .pending, bytes: 0),
            CareStudioLiveCategory(id: "skipped", title: L10n.text("已跳过 \(ByteFormat.count(progress.skippedItemCount))", "Skipped \(ByteFormat.count(progress.skippedItemCount))"),
                                   systemImage: "forward", state: progress.skippedItemCount > 0 ? .found : .pending, bytes: 0),
            CareStudioLiveCategory(id: "failed", title: L10n.text("未完成 \(ByteFormat.count(progress.failedItemCount))", "Not done \(ByteFormat.count(progress.failedItemCount))"),
                                   systemImage: "exclamationmark", state: progress.failedItemCount > 0 ? .failed : .pending, bytes: 0)
        ]
        if progress.deletedItemCount > 0 {
            items.insert(CareStudioLiveCategory(id: "deleted",
                title: L10n.text("已从废纸篓删除 \(ByteFormat.count(progress.deletedItemCount))", "Deleted from Trash \(ByteFormat.count(progress.deletedItemCount))"),
                systemImage: "xmark.bin", state: .found, bytes: 0), at: 1)
        }
        return items
    }

    var body: some View {
        CareStudioRunningPage(
            module: module,
            title: title,
            detail: detail,
            categories: counts,
            headlineValue: progress.map {
                L10n.text("\($0.processedItemCount) / \($0.totalItemCount) 项", "\($0.processedItemCount) of \($0.totalItemCount) items")
            },
            progress: fraction,
            actionTitle: isCancelling ? L10n.text("正在停止", "Stopping") : L10n.text("停止", "Stop"),
            canStop: onCancel != nil && !isCancelling,
            footnote: L10n.text("只处理已确认的项目 · 移入废纸篓后逐项核对", "Confirmed items only · Each move is verified"),
            accessory: AnyView(VStack(spacing: 12) {
                if !tasks.isEmpty {
                    CareStudioCleaningTaskList(module: module, tasks: tasks)
                }
                stages
            }),
            accessoryMaxWidth: tasks.isEmpty ? 390 : 480,
            artFraction: tasks.isEmpty ? 0.42 : 0.22,
            artMaxSide: tasks.isEmpty ? CareStudioMetrics.runningArtSide : 150,
            stopConfirmation: .cleanup,
            onStop: { onCancel?() })
#if DEBUG
            .layoutProbe("careStudio.cleaning")
#endif
    }
}

/// Finished: the success picture, the result title and one honest number —
/// what moved to the Trash, never "freed" (D93) — then the tally and every
/// skipped or failed item, and Done as the round button.
struct CareStudioCleanupCompletedLayout<Content: View, Actions: View>: View {
    let module: CareStudioModule
    let title: String
    let summary: String
    let movedBytes: Int64
    let note: String
    let onDone: () -> Void
    var doneEnabled = true
    /// D214: a run that never started shows no success mark and goes Back.
    var showsSuccess = true
    var doneTitle = L10n.text("完成", "Done")
    /// False when there is nothing for the panel (a run that never started).
    var showsContent = true
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    /// D154 batch 3P: the amount counts up once, here and not in the column,
    /// which a relayout rebuilds.
    @State private var counted = false

    var body: some View {
        CareStudioPageFrame(module: module, footnote: note) {
            GeometryReader { proxy in
                // Scrolls only when the issues and details do not fit.
                ViewThatFits(in: .vertical) {
                    column(height: proxy.size.height)
                    ScrollView { column(height: proxy.size.height) }
                        .scrollIndicators(.hidden)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .onAppear { counted = true }
        } action: {
            CareStudioActionButton(module: module, title: doneTitle, action: onDone)
                .disabled(!doneEnabled)
                .keyboardShortcut(.defaultAction)
        }
#if DEBUG
        .layoutProbe("careStudio.completed")
#endif
    }

    private func column(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            CareStudioArt(module: module, side: max(110, min(190, height * 0.26)), showsSuccess: showsSuccess)
                .padding(.top, 10)
            Text(title)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(CareStudioInk.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
#if DEBUG
                .layoutProbe("careStudio.completed.title")
#endif
            if movedBytes > 0 {
                VStack(spacing: 2) {
                    CareStudioCountingText(ByteFormat.storageString(movedBytes), counted: counted, alignment: .center,
                                           delay: CareStudioMotion.countAfterSuccess)
                        .font(.system(size: 34, weight: .semibold))
                        .monospacedDigit()
                    Text(L10n.text("已移到废纸篓", "moved to the Trash"))
                        .font(.system(size: 13))
                        .foregroundStyle(CareStudioInk.secondary)
                }
                .foregroundStyle(CareStudioInk.primary)
                .padding(.top, 8)
            }
            Text(summary)
                .font(.system(size: 14))
                .foregroundStyle(CareStudioInk.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)
                .padding(.top, 8)
            if showsContent {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(16)
                .frame(maxWidth: 520, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
                    .fill(CareStudioInk.panelFill))
                .overlay(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
                    .strokeBorder(CareStudioInk.hairline, lineWidth: 1))
                .padding(.top, 16)
            }
            HStack(spacing: 10) { actions }
                .padding(.top, 14)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}
