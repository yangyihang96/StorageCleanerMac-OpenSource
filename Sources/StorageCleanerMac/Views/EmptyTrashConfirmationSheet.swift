import SwiftUI

/// The binding ContentView presents the Empty Trash confirmation with.
@MainActor
enum EmptyTrashConfirmationPresentation {
    static func binding(for store: ScanStore) -> Binding<Bool> {
        Binding {
            store.pendingEmptyTrash != nil
        } set: { isPresented in
            if !isPresented {
                store.cancelEmptyTrash()
            }
        }
    }
}

/// D101 L5: the menu's Empty Trash with D23's two confirmations. Count and
/// size come from the list frozen when the confirmation opened, and only
/// those entries are deleted.
struct EmptyTrashConfirmationSheet: View {
    @Environment(\.moduleTheme) private var theme
    @ObservedObject var store: ScanStore
    let frozen: FrozenTrash
    /// Built once: the frozen list does not change while the sheet is open.
    private let facts: OperationConfirmationFacts
    @State private var acknowledgesPermanentDeletion = false
    @State private var acknowledgesTrashContentsReviewed = false

    init(store: ScanStore, frozen: FrozenTrash) {
        self.store = store
        self.frozen = frozen
        facts = .emptyTrash(frozen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            HStack(spacing: AppDesignTokens.Spacing.medium) {
                Image(systemName: "trash.slash.fill")
                    .font(AppDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(AppDesignTokens.Palette.destructive)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("清空废纸篓？", "Empty Trash?"))
                        .font(AppDesignTokens.Typography.sectionTitle)
                    Text(L10n.text(
                        "\(ByteFormat.count(facts.itemCount)) 项 · \(ByteFormat.storageString(frozen.summary.totalBytes)) · 永久删除",
                        "\(L10n.items(facts.itemCount)) · \(ByteFormat.storageString(frozen.summary.totalBytes)) · Delete Permanently"
                    ))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Spacer()
            }

            // D93: the six fixed fields every confirmation lists.
            OperationConfirmationFactsView(facts: facts)

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                Label(
                    L10n.text("清空废纸篓 · 不可恢复", "Empty Trash · Cannot Be Undone"),
                    systemImage: "trash.slash.fill"
                )
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(AppDesignTokens.Palette.destructive)

                Text(L10n.text(
                    "只删除打开这个确认时废纸篓里的 \(ByteFormat.count(facts.itemCount)) 项，删除后无法恢复；其中如有早先清理移入的文件，之后也无法再从“操作记录”恢复。之后放入废纸篓的项目，以及名称相同但已被替换的项目，都会保留。",
                    "Only the \(ByteFormat.count(facts.itemCount)) item(s) in the Trash when this confirmation opened are deleted, and they cannot be restored. Files an earlier cleanup moved there can no longer be restored from Operation History. Items put in the Trash afterwards, and items replaced under the same name, are kept."
                ))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $acknowledgesPermanentDeletion) {
                    Text(L10n.text(
                        "我了解这些项目会被永久删除，无法恢复",
                        "I understand these items will be permanently deleted and cannot be restored"
                    ))
                    .font(AppDesignTokens.Typography.metadata)
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $acknowledgesTrashContentsReviewed) {
                    Text(L10n.text(
                        "我已确认废纸篓里没有需要保留的文件",
                        "I confirmed the Trash holds nothing I need to keep"
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

            Divider()
            HStack {
                Button(L10n.text("取消", "Cancel")) {
                    store.cancelEmptyTrash()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                // No default-action shortcut: Return never deletes permanently.
                Button {
                    store.confirmEmptyTrash(
                        acknowledgesPermanentDeletion: acknowledgesPermanentDeletion,
                        acknowledgesTrashContentsReviewed: acknowledgesTrashContentsReviewed
                    )
                } label: {
                    Label(L10n.text("永久删除", "Permanently Delete"), systemImage: "trash.slash")
                }
                .appButtonChrome(.destructive)
                .disabled(
                    !acknowledgesPermanentDeletion
                        || !acknowledgesTrashContentsReviewed
                        || !store.canRequestEmptyTrash
                )
            }
        }
        .padding(20)
        .frame(width: 416)
        .background(ModuleBackground(theme: theme))
        .foregroundStyle(theme.primaryText)
        .clipShape(RoundedRectangle(cornerRadius: AppDesignTokens.Layout.heroRadius, style: .continuous))
    }
}
