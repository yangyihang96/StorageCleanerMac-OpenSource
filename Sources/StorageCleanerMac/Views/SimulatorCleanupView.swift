import SwiftUI

/// D101 G2: the entry on Developer Tools & Artifacts. Shown only when the
/// selected developer tools have simctl (checked from files, no process).
struct SimulatorCleanupEntryButton: View {
    let coordinator: HeavyWorkCoordinator
    @State private var presented = false
    private let isAvailable = SimulatorToolLocator.developerDirectory() != nil

    var body: some View {
        if isAvailable {
            Button(L10n.text("iOS 模拟器 · 不可用设备与未用运行时", "iOS Simulators · Unavailable Devices & Unused Runtimes")) {
                presented = true
            }
            .sheet(isPresented: $presented) { SimulatorCleanupView(coordinator: coordinator) }
        }
    }
}

/// Owns one read-only listing and at most one deletion. The confirmation
/// and the deletion use the list frozen when the confirmation opened.
@MainActor
final class SimulatorCleanupController: ObservableObject {
    enum Phase: Equatable {
        case loading, loaded, deleting, finished
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var items: [SimulatorCleanupItem] = []
    /// Nothing is selected by default.
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var pending: [SimulatorCleanupItem]?
    @Published private(set) var runningOwners: [String] = []
    @Published private(set) var status = ""
    @Published private(set) var resultMessage: String?
    private let coordinator: HeavyWorkCoordinator
    private let service: SimulatorCleanupService
    private var task: Task<Void, Never>?

    init(coordinator: HeavyWorkCoordinator,
         service: SimulatorCleanupService = SimulatorCleanupService(runner: XcrunSimulatorCommandRunner())) {
        self.coordinator = coordinator
        self.service = service
    }

    var selectedItems: [SimulatorCleanupItem] { items.filter { selectedIDs.contains($0.id) } }

    func load() {
        guard phase != .deleting else { return }
        task?.cancel()
        phase = .loading
        items = []
        selectedIDs = []
        pending = nil
        status = L10n.text("正在只读读取模拟器列表…", "Reading the simulator list (read-only)…")
        let service = service
        task = Task {
            do {
                let items = try await service.items()
                let running = await service.runningOwners()
                guard !Task.isCancelled else { return }
                self.items = items
                runningOwners = running
                status = items.isEmpty
                    ? L10n.text("没有不可用的设备，也没有未使用的运行时", "No unavailable devices and no unused runtimes")
                    : L10n.text("发现 \(ByteFormat.count(items.count)) 项，默认不勾选", "Found \(L10n.items(items.count)); none selected by default")
            } catch {
                guard !Task.isCancelled else { return }
                status = L10n.text(
                    "无法读取模拟器列表：\(error.localizedDescription)",
                    "Could not read the simulator list: \(error.localizedDescription)"
                )
            }
            phase = .loaded
        }
    }

    func setSelected(_ item: SimulatorCleanupItem, _ selected: Bool) {
        guard phase == .loaded, pending == nil else { return }
        if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
    }

    func requestDeletion() {
        let selected = selectedItems
        guard phase == .loaded, !selected.isEmpty else { return }
        pending = selected
    }

    func cancelDeletion() {
        pending = nil
    }

    /// D23's two confirmations, as the menu's Empty Trash (D101 L5).
    func confirmDeletion(
        acknowledgesPermanentDeletion: Bool,
        acknowledgesSimulatorDataReviewed: Bool
    ) {
        guard let frozen = pending,
              acknowledgesPermanentDeletion,
              acknowledgesSimulatorDataReviewed,
              phase == .loaded else { return }
        pending = nil
        phase = .deleting
        status = L10n.text("正在通过 simctl 逐项删除…", "Deleting through simctl, one item at a time…")
        let coordinator = coordinator, service = service
        task = Task {
            do {
                let result = try await coordinator.withLease(owner: .cleanup) { _ in
                    await service.delete(frozen)
                }
                resultMessage = result.message
            } catch {
                resultMessage = error.localizedDescription
            }
            selectedIDs = []
            phase = .finished
            status = L10n.text("可重新检查查看剩余项目", "Check again to see what remains")
        }
    }

    func close() {
        guard phase != .deleting else { return }
        task?.cancel()
    }
}

struct SimulatorCleanupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.moduleTheme) private var theme
    @StateObject private var controller: SimulatorCleanupController
    @State private var acknowledgesPermanentDeletion = false
    @State private var acknowledgesSimulatorDataReviewed = false

    init(coordinator: HeavyWorkCoordinator) {
        _controller = StateObject(wrappedValue: SimulatorCleanupController(coordinator: coordinator))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            header
            if !controller.runningOwners.isEmpty {
                Label(
                    L10n.text("Xcode 或模拟器正在运行；删除时会跳过，请先退出", "Xcode or Simulator is running; deleting skips everything until they quit"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.warning)
            }
            if let message = controller.resultMessage {
                Text(message)
                    .font(AppDesignTokens.Typography.metadata)
                    .fixedSize(horizontal: false, vertical: true)
            }
            itemList
            if let pending = controller.pending {
                confirmation(pending)
            } else {
                footer
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 420)
        .background(ModuleBackground(theme: theme))
        .foregroundStyle(theme.primaryText)
        .onAppear { controller.load() }
        .onDisappear { controller.close() }
    }

    private var header: some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            Image(systemName: "iphone.gen3")
                .font(AppDesignTokens.Typography.sectionTitle)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("iOS 模拟器", "iOS Simulators"))
                    .font(AppDesignTokens.Typography.sectionTitle)
                Text(controller.status)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if controller.phase == .loading || controller.phase == .deleting {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                ForEach(controller.items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: AppDesignTokens.Spacing.small) {
                            Toggle(isOn: Binding(
                                get: { controller.selectedIDs.contains(item.id) },
                                set: { controller.setSelected(item, $0) }
                            )) {
                                Text(item.title)
                                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                            }
                            .toggleStyle(.checkbox)
                            .disabled(controller.phase != .loaded || controller.pending != nil)
                            Text(CleanupRiskPresentation.title(.reviewOnly))
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(CleanupRiskPresentation.tint(.reviewOnly))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(CleanupRiskPresentation.tint(.reviewOnly).opacity(0.12), in: Capsule())
                            Spacer()
                            Text(item.bytes.map { ByteFormat.storageString($0) } ?? L10n.text("大小未知", "Size unknown"))
                                .font(AppDesignTokens.Typography.metadata)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text(item.detail)
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.identifier)
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
        .frame(minHeight: 160)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Text(L10n.text(
                "只列出不可用的设备和没有设备在用的运行时（含预览与测试设备）。删除用 simctl 自身的命令逐项执行，永久删除，不经过废纸篓。",
                "Lists only unavailable devices and runtimes no device uses (preview and test devices included). Each is deleted with simctl's own command, permanently, without the Trash."
            ))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button(L10n.text("重新检查", "Check Again")) { controller.load() }
                    .disabled(controller.phase == .loading || controller.phase == .deleting)
                Spacer()
                Button(L10n.text("关闭", "Close")) {
                    controller.close()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(controller.phase == .deleting)
                Button {
                    acknowledgesPermanentDeletion = false
                    acknowledgesSimulatorDataReviewed = false
                    controller.requestDeletion()
                } label: {
                    Label(L10n.text("删除所选…", "Delete Selected…"), systemImage: "trash.slash")
                }
                .appButtonChrome(.destructive)
                .disabled(controller.phase != .loaded || controller.selectedIDs.isEmpty)
            }
        }
    }

    private func confirmation(_ pending: [SimulatorCleanupItem]) -> some View {
        let facts = OperationConfirmationFacts.simulatorCleanup(pending)
        return VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            // D93: the six fixed fields every confirmation lists.
            OperationConfirmationFactsView(facts: facts)
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                Label(
                    L10n.text("删除模拟器项目 · 不可恢复", "Delete Simulator Items · Cannot Be Undone"),
                    systemImage: "trash.slash.fill"
                )
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(AppDesignTokens.Palette.destructive)
                Text(L10n.text(
                    "只删除打开这个确认时选中的 \(ByteFormat.count(facts.itemCount)) 项。删除前会重新读取列表：已变为可用的设备、已有设备在用的运行时都会保留；Xcode 或模拟器正在运行时全部跳过。",
                    "Only the \(ByteFormat.count(facts.itemCount)) item(s) selected when this confirmation opened are deleted. The list is read again first: devices that became available and runtimes a device now uses are kept, and nothing runs while Xcode or Simulator is open."
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
                Toggle(isOn: $acknowledgesSimulatorDataReviewed) {
                    Text(L10n.text(
                        "我已确认这些设备里没有要保留的 App 数据；运行时需要时可在 Xcode 中重新下载",
                        "I confirmed these devices hold no app data I need; runtimes can be downloaded again in Xcode"
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
                Button(L10n.text("取消", "Cancel")) { controller.cancelDeletion() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                // No default-action shortcut: Return never deletes permanently.
                Button {
                    controller.confirmDeletion(
                        acknowledgesPermanentDeletion: acknowledgesPermanentDeletion,
                        acknowledgesSimulatorDataReviewed: acknowledgesSimulatorDataReviewed
                    )
                } label: {
                    Label(L10n.text("永久删除", "Permanently Delete"), systemImage: "trash.slash")
                }
                .appButtonChrome(.destructive)
                .disabled(!acknowledgesPermanentDeletion || !acknowledgesSimulatorDataReviewed)
            }
        }
    }
}
