import SwiftUI

/// D188: list-level selection only. Item names and bookmark contents never
/// enter this view. Both entry points keep every checkbox off by default.
struct CareStudioRecentItemsSheet: View {
    @ObservedObject var store: RecentItemsStore
    let coordinator: HeavyWorkCoordinator?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            Text(RecentItemsPresentation.title)
                .font(AppDesignTokens.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            if let result = store.result {
                completion(result)
            } else if store.confirmation != nil {
                confirmation
            } else {
                review
            }
            if let error = store.error { Text(error).foregroundStyle(AppDesignTokens.Palette.warning) }
            if store.isCleaning {
                ProgressView(L10n.text("正在移到废纸篓并核实列表…", "Moving to Trash and verifying lists…"))
            }
            HStack {
                Button(L10n.text("关闭", "Close"), action: onClose).disabled(store.isCleaning)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if store.result == nil, store.confirmation != nil {
                    Button(L10n.text("选择列表", "Choose Lists"), action: store.editSelection).disabled(store.isCleaning)
                    Button(L10n.text("确认移到废纸篓", "Confirm Move to Trash")) {
                        guard let coordinator else { return }
                        Task { await store.clean(confirmed: true, coordinator: coordinator) }
                    }
                    .disabled(store.isCleaning || store.confirmation?.isEmpty != false || coordinator == nil)
                    .buttonStyle(.borderedProminent)
                } else if store.result == nil {
                    Button(L10n.text("移除", "Remove"), action: store.prepareConfirmation)
                        .disabled(store.selectedIDs.isEmpty || store.isScanning)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(AppDesignTokens.Layout.pagePadding)
        .frame(width: 660)
        .frame(minHeight: 440, maxHeight: 700)
        .interactiveDismissDisabled(store.isCleaning)
#if DEBUG
        .layoutProbe(store.result != nil ? "careStudio.protection.recentItems.result" :
                        (store.confirmation != nil ? "careStudio.protection.recentItems.confirmation" : "careStudio.protection.recentItems.review"))
#endif
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            Text(RecentItemsPresentation.detail).font(AppDesignTokens.Typography.metadata)
            Text(L10n.text("默认不勾选。请按列表选择要清理的记录。", "Nothing is selected by default. Choose the lists you want to clear."))
                .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
            if let snapshot = store.snapshot {
                Text(RecentItemsPresentation.summary(snapshot))
                if snapshot.unreadableLocations > 0 {
                    Text(L10n.text("部分列表位置无法读取，结果不完整。", "Some list locations could not be read; results are incomplete."))
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                        ForEach(RecentItemsCategory.allCases, id: \.self) { category in
                            let lists = snapshot.lists.filter { $0.category == category }
                            if !lists.isEmpty {
                                Text(RecentItemsPresentation.title(for: category)).font(AppDesignTokens.Typography.compactLabelEmphasis)
                                ForEach(lists) { list in
                                    Toggle(isOn: Binding(get: { store.selectedIDs.contains(list.id) },
                                                        set: { store.setSelected($0, listID: list.id) })) {
                                        HStack(spacing: 8) {
                                            if let bundleID = list.bundleIdentifier, let icon = store.applications[bundleID]?.icon {
                                                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                                            }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(store.name(for: list))
                                                Text(list.url.lastPathComponent).font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text(RecentItemsPresentation.count(list.entryCount)).foregroundStyle(.secondary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .accessibilityIdentifier("recentItems.list.\(list.url.lastPathComponent)")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if snapshot.lists.isEmpty { Text(L10n.text("没有可列出的最近使用列表。", "No recent-item lists to show.")) }
            }
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            ForEach(RecentItemsPresentation.confirmationNotes, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
            OperationConfirmationFactsView(facts: store.confirmationFacts)
            if store.confirmation?.isEmpty != false {
                Text(L10n.text("尚未勾选列表。请先选择要移除的列表。", "No lists are checked. Choose lists before removing them."))
                    .foregroundStyle(.secondary)
            }
            if coordinator == nil {
                Text(L10n.text("预览中不能执行清理。", "Cleanup is unavailable in this preview."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func completion(_ result: RecentItemsCleanupResult) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            OperationCompletionTallyView(tally: OperationCompletionTally(report: result.report))
            Text(RecentItemsPresentation.restart(result.restart)).font(AppDesignTokens.Typography.metadata)
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                    ForEach(result.report.items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(URL(fileURLWithPath: item.sourcePath).lastPathComponent)
                            Text(RecentItemsPresentation.verification(result.verification[item.sourcePath] ?? .unknown))
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
