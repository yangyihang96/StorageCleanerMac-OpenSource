import SwiftUI

/// D93：确认页的六个固定字段与可展开的对象清单。所有清理／卸载类
/// 确认页共用，文字全部换行显示、不截断（D77 的 1280×763 版式）。
struct OperationConfirmationFactsView: View {
    let facts: OperationConfirmationFacts
    /// 清单默认收起；对象清单在页面别处已完整列出时可关掉。
    var showsItemList = true
    @State private var showsItems = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
            // 六个字段整段换行；超出上限时在面板内滚动而不是撑高表单（D77）。
            ViewThatFits(in: .vertical) {
                fieldRows
                ScrollView { fieldRows }
            }
            .frame(maxHeight: Self.fieldRowsMaxHeight)
            if showsItemList, !facts.items.isEmpty {
                DisclosureGroup(
                    L10n.text("展开对象清单（\(ByteFormat.count(facts.itemCount)) 项）", "Show Item List (\(ByteFormat.count(facts.itemCount)))"),
                    isExpanded: $showsItems
                ) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
                            ForEach(facts.items) { item in
                                OperationConfirmationItemRow(item: item)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
                .font(AppDesignTokens.Typography.metadata)
            }
        }
        .padding(AppDesignTokens.Layout.compactPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.rowRadius,
            tint: AppDesignTokens.Palette.information,
            prominence: .quiet
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("执行前核对", "Before You Confirm"))
    }

    /// 字段区最大高度；1280×763 下确认表其余内容与按钮仍能完整显示。
    static let fieldRowsMaxHeight: CGFloat = 240

    private var fieldRows: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
            ForEach(facts.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.medium) {
                    Text(row.field.title)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(row.value)
                        .foregroundStyle(row.isWarning ? AppDesignTokens.Palette.warning : AppDesignTokens.Palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(AppDesignTokens.Typography.metadata)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OperationConfirmationItemRow: View {
    let item: OperationConfirmationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.small) {
                Text(item.title)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: AppDesignTokens.Spacing.small)
                Text(item.bytes.map { ByteFormat.storageString($0) } ?? L10n.text("大小未知", "Unknown size"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            if let path = item.path {
                Text(path)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(AppDesignTokens.Typography.metadata)
        .accessibilityElement(children: .combine)
    }
}

/// D93：完成页的四组统计（完成／跳过／失败／待核实）、容量口径，
/// 以及可展开的逐项原因。“移到废纸篓”只写已移到废纸篓，不写已释放。
struct OperationCompletionTallyView: View {
    let tally: OperationCompletionTally
    /// 页面别处已逐项列出跳过／失败原因时可关掉。
    var showsEntryDetails = true
    /// 页面自己已提示回执不完整时关掉，避免同一提示出现两次（P2-7）。
    var showsReceiptNote = true
    @State private var showsEntries = false

    private var issueEntries: [OperationCompletionEntry] {
        tally.entries.filter { $0.bucket != .completed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppDesignTokens.Spacing.medium) { bucketLabels }
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) { bucketLabels }
            }
            .font(AppDesignTokens.Typography.compactLabelEmphasis)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tally.headline)

            ForEach(showsReceiptNote ? tally.capacityLines : tally.spaceLines, id: \.self) { line in
                Text(line)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsEntryDetails, !issueEntries.isEmpty {
                DisclosureGroup(
                    L10n.text("逐项原因（\(ByteFormat.count(issueEntries.count)) 项）", "Reasons per Item (\(ByteFormat.count(issueEntries.count)))"),
                    isExpanded: $showsEntries
                ) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
                            ForEach(issueEntries) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.small) {
                                    Image(systemName: entry.bucket.systemImage)
                                        .foregroundStyle(tint(entry.bucket))
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.count > 1 ? "\(entry.title) · \(ByteFormat.count(entry.count))" : entry.title)
                                            .font(AppDesignTokens.Typography.compactLabelEmphasis)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text("\(entry.bucket.title)\(L10n.text("：", ": "))\(entry.detail)")
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .font(AppDesignTokens.Typography.metadata)
                                .help(entry.path ?? entry.title)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
                .font(AppDesignTokens.Typography.metadata)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var bucketLabels: some View {
        ForEach(OperationCompletionBucket.allCases, id: \.self) { bucket in
            Label("\(bucket.title) \(tally.count(bucket))", systemImage: bucket.systemImage)
                .foregroundStyle(tally.count(bucket) > 0 ? tint(bucket) : .secondary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    private func tint(_ bucket: OperationCompletionBucket) -> Color {
        switch bucket {
        case .completed: AppDesignTokens.Palette.success
        case .skipped: .secondary
        case .failed: AppDesignTokens.Palette.destructive
        case .needsVerification: AppDesignTokens.Palette.warning
        }
    }
}

/// D93 ③：结果行的三段说明（属于什么应用、处理后影响、为什么预选）。
struct CleanupRuleExplanationView: View {
    let explanation: CleanupRuleExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(explanation.lines, id: \.title) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                    Text(line.value)
                        .font(AppDesignTokens.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
