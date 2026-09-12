import SwiftUI

struct ItemDetailField: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
}

enum ItemDetailPresentation {
    static func fields(for item: StorageItem) -> [ItemDetailField] {
        var fields = [ItemDetailField]()
        append(
            id: "type",
            title: L10n.text("类型", "Type"),
            value: item.kind,
            to: &fields
        )
        if normalized(item.groupTitle) != normalized(item.kind) {
            append(
                id: "source",
                title: L10n.text("来源", "Source"),
                value: item.groupTitle,
                to: &fields
            )
        }
        append(
            id: "reason",
            title: L10n.text("判断", "Reason"),
            value: item.reason,
            to: &fields
        )
        append(
            id: "risk",
            title: L10n.text("风险", "Risk"),
            value: item.risk,
            to: &fields
        )
        if !isNoRequirement(item.requiresClose) {
            append(
                id: "close",
                title: L10n.text("关闭", "Close"),
                value: item.requiresClose,
                to: &fields
            )
        }
        return fields
    }

    private static func append(
        id: String,
        title: String,
        value: String,
        to fields: inout [ItemDetailField]
    ) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        fields.append(ItemDetailField(id: id, title: title, value: value))
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isNoRequirement(_ value: String) -> Bool {
        ["", "无", "none"].contains(normalized(value))
    }
}

struct ItemDetailView: View {
    @ObservedObject var store: ScanStore
    let item: StorageItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                safetyBlock
                actionRow
                detailGrid
                pathBlock
            }
            .padding(AppDesignTokens.Layout.pagePadding)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.tier.systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.title2.weight(.semibold))
                .foregroundStyle(item.tier.color)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(AppDesignTokens.Typography.pageTitle)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Label(item.tier.title, systemImage: item.tier.systemImage)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(item.tier.color)

                    Divider()
                        .frame(height: 14)

                    Text(ByteFormat.string(item.sizeBytes))
                        .font(AppDesignTokens.Typography.metadata)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    if item.status == .movedToTrash {
                        Divider()
                            .frame(height: 14)

                        Label(L10n.text("已移到废纸篓", "Moved to Trash"), systemImage: "checkmark")
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var safetyBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: safetyIcon)
                .symbolRenderingMode(.hierarchical)
                .font(.title3.weight(.semibold))
                .foregroundStyle(item.tier.color)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(safetyTitle)
                    .font(AppDesignTokens.Typography.sectionTitle)
                Text(item.recommendation)
                    .font(AppDesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.rowRadius, tint: item.tier.color)
    }

    private var pathBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("路径", "Path"))
                    .font(AppDesignTokens.Typography.smallLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.copyPath(item.path)
                } label: {
                    Label(L10n.text("复制", "Copy"), systemImage: "doc.on.doc")
                }
                .controlSize(.regular)
            }
            Text(item.path)
                .font(AppDesignTokens.Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.rowRadius)
    }

    private var detailGrid: some View {
        let fields = ItemDetailPresentation.fields(for: item)

        return VStack(spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                if index > 0 {
                    Divider()
                }
                DetailLine(title: field.title, value: field.value)
            }
        }
        .glassPanel(cornerRadius: AppDesignTokens.Layout.rowRadius)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if item.canMoveToTrash {
                Button(role: .destructive) {
                    store.requestTrash(item)
                } label: {
                    Label(L10n.text("移到废纸篓", "Move to Trash"), systemImage: "trash")
                }
                .appButtonChrome(.primary)
                .disabled(!store.canRequestTrash(item))
            }

            Button {
                store.reveal(item.openPath)
            } label: {
                Label(L10n.text("在访达中显示", "Show in Finder"), systemImage: "folder")
            }

            Spacer()
        }
    }

    private var safetyIcon: String {
        switch item.tier {
        case .green: "checkmark"
        case .yellow: "questionmark"
        case .red: "exclamationmark.triangle"
        case .other: "info"
        }
    }

    private var safetyTitle: String {
        switch item.tier {
        case .green: L10n.text("可清理，但会先进入废纸篓", "Cleanable, but it will go to Trash first")
        case .yellow: L10n.text("需要人工判断", "Manual review required")
        case .red: L10n.text("谨慎处理", "Handle carefully")
        case .other: L10n.text("仅作为占用参考", "Storage reference only")
        }
    }
}

private struct DetailLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(AppDesignTokens.Typography.smallLabel)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(AppDesignTokens.Typography.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
    }
}
