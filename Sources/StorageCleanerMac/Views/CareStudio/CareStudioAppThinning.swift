import SwiftUI

@MainActor
final class UniversalBinaryViewModel: ObservableObject {
    @Published private(set) var inventory: UniversalBinaryInventory?
    @Published private(set) var isBusy = false
    @Published private(set) var results: [UniversalBinaryResult] = []
    @Published private(set) var message: String?

    func scan(coordinator: HeavyWorkCoordinator) async {
        guard !isBusy else { return }
        isBusy = true
        inventory = nil
        defer { isBusy = false }
        let worker = Task.detached(priority: .utility) {
            try await coordinator.withLease(owner: .mainScan) { _ in
                await UniversalBinaryService.inventory()
            }
        }
        do {
            let scanned = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            if !Task.isCancelled { inventory = scanned; message = nil }
        } catch {
            message = L10n.text("暂时无法检查应用，请在当前任务结束后重新扫描。", "Apps could not be checked. Scan again after the current task finishes.")
        }
    }

    func thin(_ apps: [UniversalBinaryCandidate], coordinator: HeavyWorkCoordinator) async {
        guard !isBusy, !apps.isEmpty else { return }
        isBusy = true
        results = []
        defer { isBusy = false }
        let worker = Task.detached(priority: .utility) {
            try await coordinator.withLease(owner: .cleanup) { lease in
                await UniversalBinaryService.execute(apps, beforeMutation: {
                    try await coordinator.requireValid(lease, owner: .cleanup)
                })
            }
        }
        do {
            results = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            let attempted = Set(results.map(\.id))
            inventory?.apps.removeAll { attempted.contains($0.id) }
            message = nil
        } catch {
            message = L10n.text("其他任务正在执行，未改动应用。请稍后再试。", "Another task is running. Apps were kept unchanged; try again later.")
        }
    }
}

/// D184 is reviewed separately because it modifies signed applications, rather than deleting junk.
struct CareStudioAppThinning: View {
    @ObservedObject var model: UniversalBinaryViewModel
    @ObservedObject var store: ScanStore
    let onClose: () -> Void
    @State private var selected = Set<String>()
    @State private var pending: [UniversalBinaryCandidate]?

    static var warning: String {
        L10n.text("瘦身会改动应用文件。原应用会移入废纸篓，可从操作记录放回到原文件夹（以“瘦身前”副本名保存）。个别应用的增量更新可能失败，需要重新下载安装。清空废纸篓后才释放空间。",
            "Thinning changes application files. The original goes to Trash and can be put back from Operation History into its folder as a “before thinning” copy. Some incremental updates may fail and require downloading and reinstalling the app. Space is freed only after emptying Trash.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(L10n.text("应用瘦身 · 需审阅", "App Thinning · Review Required"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppDesignTokens.Palette.caution).font(.title2.bold())
                Spacer()
                Button(L10n.text("完成", "Done"), action: onClose).disabled(model.isBusy)
            }
            if let pending {
                Text(L10n.text("确认瘦身所选应用？", "Thin the Selected Apps?")).font(.headline)
                Text(Self.warning).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(pending) { app in appLabel(app) }
                    }
                }
                HStack {
                    Button(L10n.text("返回", "Back")) { self.pending = nil }
                    Spacer()
                    Button(L10n.text("确认应用瘦身", "Confirm App Thinning")) {
                        self.pending = nil
                        selected.removeAll()
                        Task {
                            await model.thin(pending, coordinator: store.heavyWorkCoordinator)
                            store.refreshOperationReports()
                        }
                    }
                    .accessibilityIdentifier("appThinning.confirm")
                }
            } else {
                Text(Self.warning).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.inventory?.apps ?? []) { app in
                            Toggle(isOn: Binding(get: { selected.contains(app.id) }, set: { value in
                                if value { selected.insert(app.id) } else { selected.remove(app.id) }
                            })) { appLabel(app) }
                                .tint(AppDesignTokens.Palette.caution).disabled(model.isBusy)
                                .accessibilityIdentifier("appThinning.select.\(app.id)")
                        }
                        if let inventory = model.inventory {
                            Text(L10n.text("已跳过 \(ByteFormat.count(inventory.rootOwnedAppCount)) 个 root 拥有的应用，本批不处理。",
                                "Skipped \(ByteFormat.count(inventory.rootOwnedAppCount)) root-owned apps; they are excluded from this batch."))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            ForEach(inventory.skipped.keys.sorted(by: { $0.title < $1.title }), id: \.self) { reason in
                                Text("\(reason.title) · \(ByteFormat.count(inventory.skipped[reason] ?? 0))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if inventory.unreadableLocations > 0 {
                                Text(L10n.text("\(ByteFormat.count(inventory.unreadableLocations)) 个扫描位置无法读取，结果不完整。",
                                    "\(ByteFormat.count(inventory.unreadableLocations)) scan location(s) could not be read; results are incomplete."))
                            }
                            if inventory.apps.isEmpty && model.results.isEmpty {
                                Text(L10n.text("没有发现符合安全条件的可瘦身应用。", "No apps meet the safety requirements for thinning."))
                            }
                        }
                        ForEach(model.results) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.name + " · " + status(result.status)).fontWeight(.semibold)
                                Text(result.detail).font(.system(size: 12)).textSelection(.enabled)
                                if result.savedBytes > 0 {
                                    Text(L10n.text("清空废纸篓后预计释放 \(ByteFormat.storageString(result.savedBytes))",
                                        "Estimated to free \(ByteFormat.storageString(result.savedBytes)) after emptying Trash"))
                                }
                            }
                        }
                        if let message = model.message { Text(message) }
                    }
                }
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Button(L10n.text("重新扫描", "Scan Again")) {
                        selected.removeAll()
                        Task { await model.scan(coordinator: store.heavyWorkCoordinator) }
                    }.disabled(model.isBusy)
                    Spacer()
                    Button(L10n.text("审阅所选应用…", "Review Selected Apps…")) {
                        pending = model.inventory?.apps.filter { selected.contains($0.id) }
                    }
                    .disabled(model.isBusy || selected.isEmpty)
                    .accessibilityIdentifier("appThinning.review")
                }
            }
        }
        .padding(22).frame(width: 680, height: 580)
        .interactiveDismissDisabled(model.isBusy)
    }

    private func appLabel(_ app: UniversalBinaryCandidate) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(app.name).fontWeight(.semibold)
                Text(L10n.text("版本 \(app.version) · \(ByteFormat.count(app.files.count)) 个文件",
                    "Version \(app.version) · \(ByteFormat.count(app.files.count)) files"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.storageString(app.savedBytes)).monospacedDigit()
        }
    }

    private func status(_ value: UniversalBinaryResult.Status) -> String {
        switch value {
        case .success: L10n.text("成功", "Succeeded")
        case .skipped: L10n.text("已跳过", "Skipped")
        case .failed: L10n.text("失败", "Failed")
        }
    }
}
