import FileOperationShared
import SwiftUI

/// A separate, opt-in selection: never part of the default junk/Smart Care run.
struct CareStudioSystemCaches: View {
    @ObservedObject var store: ScanStore
    let onClose: () -> Void
    @State private var selected = Set<SystemCacheID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("系统缓存", "System Caches")).font(.title2.bold())
                Spacer()
                Button(L10n.text("完成", "Done"), action: onClose).disabled(store.isClearingSystemCaches)
            }
            if let plan = store.pendingSystemCacheClear {
                confirmation(plan)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(L10n.text("系统会自动重建这些缓存。清除会永久删除缓存内容，不能撤销；需要管理员密码。",
                                       "The system rebuilds these caches. Clearing permanently deletes their contents and cannot be undone; an administrator password is required."))
                        ForEach(store.systemCacheInventory?.items ?? [], id: \.cache) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(isOn: Binding(get: { selected.contains(item.cache) }, set: { on in
                                    if on { selected.insert(item.cache) } else { selected.remove(item.cache) }
                                })) {
                                    HStack {
                                        Text(item.cache.title).fontWeight(.semibold)
                                        Spacer()
                                        Text(item.allocatedBytes.map { ByteFormat.storageString($0) }
                                             ?? L10n.text("不可用", "Unavailable"))
                                    }
                                }
                                .disabled(store.isClearingSystemCaches || !SystemCachePresentation.isSelectable(item))
                                .accessibilityIdentifier("systemCache.select.\(item.cache.rawValue)")
                                Text(item.cache.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                                if item.failure != nil {
                                    Text(L10n.text("只量出了部分大小，或此缓存暂时无法读取。", "Only part of the size was measured, or this cache cannot currently be read."))
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let message = store.systemCacheResultMessage {
                            Text(message).textSelection(.enabled).accessibilityIdentifier("systemCache.result")
                        }
                    }
                }
                HStack {
                    if store.isClearingSystemCaches { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(L10n.text("清除…", "Clear…")) { store.requestSystemCacheClear(selected) }
                        .disabled(selected.isEmpty || store.isClearingSystemCaches || store.systemCacheInventory == nil)
                        .accessibilityIdentifier("systemCache.reviewClear")
                }
            }
        }
        .padding(22)
        .frame(width: 600, height: 530)
        .onDisappear { store.cancelSystemCacheClear() }
#if DEBUG
        .layoutProbe("careStudio.systemCaches")
#endif
    }

    private func confirmation(_ plan: SystemCacheClearPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("永久清除所选系统缓存？", "Permanently Clear Selected System Caches?"))
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    OperationConfirmationFactsView(facts: plan.facts, showsItemList: false)
                    ForEach(plan.items, id: \.cache) { item in
                        HStack {
                            Text(item.cache.title)
                            Spacer()
                            Text(item.allocatedBytes.map { ByteFormat.storageString($0) } ?? L10n.text("未知", "Unknown"))
                        }
                    }
                }
            }
            HStack {
                Button(L10n.text("返回", "Back")) { store.cancelSystemCacheClear() }
                Spacer()
                Button(L10n.text("永久清除", "Clear Permanently"), role: .destructive) {
                    selected.removeAll()
                    Task { await store.confirmSystemCacheClear(planID: plan.id) }
                }
                .accessibilityIdentifier("systemCache.confirmClear")
            }
        }
#if DEBUG
        .layoutProbe("careStudio.systemCaches.confirmation")
#endif
    }
}
