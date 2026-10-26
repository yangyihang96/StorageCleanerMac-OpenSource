import SwiftUI

/// D-FP2: the maintenance tasks page in the studio review layout. Tasks
/// this app runs have a tick; the others say where they are done and why.
/// What a task will do is shown before it runs (Mac Sai's practice).
struct SystemMaintenancePage: View {
    @ObservedObject var store: SystemMaintenanceStore
    let module: CareStudioModule
    let onBack: () -> Void
    /// Opens this app's Free Up RAM page (wired by the module).
    var openFreeUpMemory: () -> Void = {}

    @State private var current: SystemMaintenanceTaskID = .speedUpMail
    @State private var query = ""
    @State private var sort: ToolboxSort = .name
    @State private var confirmsRun = false

    var body: some View {
        ToolboxManagerPanel(
            module: module,
            title: L10n.text("维护任务", "Maintenance Tasks"),
            query: $query,
            sortOptions: [],
            sort: $sort,
            showsSearch: false,
            categoryWidth: 268,
            onBack: onBack
        ) {
            taskColumn
        } rows: {
            detailColumn
        } footer: {
            ToolboxFooter(
                selectedCount: store.selectedTasks.count,
                actionTitle: store.isRunning ? L10n.text("正在运行…", "Running…") : L10n.text("运行", "Run"),
                actionEnabled: !store.selectedTasks.isEmpty && !store.isRunning,
                action: { confirmsRun = true }
            ) {
                EmptyView()
            }
        }
        .maintenanceRunConfirmation(store, isPresented: $confirmsRun) { store.runSelected() }
        .onAppear {
            if !store.hasStatuses { store.refresh() }
        }
    }

    // MARK: Columns

    private var taskColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SystemMaintenanceTaskID.allCases) { id in
                    let status = store.status(of: id)
                    ToolboxCategoryRow(
                        module: module,
                        title: id.title,
                        detail: modeText(status),
                        systemImage: id.systemImage,
                        art: id.art,
                        isCurrent: id == current,
                        tick: status?.mode.isRunnable == true ? (store.isSelected(id) ? .checked : .unchecked) : nil,
                        tickEnabled: store.canSelect(id),
                        onSelect: { current = id },
                        onToggle: { store.toggle(id) }
                    )
                }
            }
            .padding(10)
        }
    }

    private func modeText(_ status: SystemMaintenanceStatus?) -> String {
        guard let status else { return L10n.text("正在读取…", "Reading…") }
        if status.isRecommended { return L10n.text("建议运行", "Recommended") }
        if let blocker = status.blocker { return blocker }
        return switch status.mode {
        case .runnable: L10n.text("可在这里运行", "Runs here")
        case .elsewhere(.freeUpMemoryPage): L10n.text("在“释放内存”页运行", "Runs on Free Up RAM")
        case .elsewhere: L10n.text("在系统应用中完成", "Done in a system app")
        case .informational: L10n.text("只显示，由系统管理", "Shown only; macOS manages it")
        case .administratorRequired: L10n.text("需要管理员权限", "Needs an administrator")
        case .notNeeded: L10n.text("这版系统无需运行", "Not needed on this macOS")
        }
    }

    private var detailColumn: some View {
        let status = store.status(of: current)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let message = store.errorMessage {
                    ToolboxNotice(tone: .warning, title: message, onDismiss: store.dismissError)
                }
                ToolboxSectionHeader(title: current.title, summary: current.summary) {
                    actions(for: current, status: status)
                }
                if let status {
                    ForEach(Array(status.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundStyle(CareStudioManagerInk.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 3)
                    }
                    if let blocker = status.blocker {
                        ToolboxNotice(tone: .warning, title: blocker)
                    }
                } else {
                    ProgressView().controlSize(.small).padding(16)
                }
                if let consequence = current.consequence {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("运行后会怎样", "What Happens When It Runs"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(consequence)
                            .font(.system(size: 12))
                            .foregroundStyle(CareStudioManagerInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(CareStudioManagerInk.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CareStudioManagerInk.field))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                if let command = current.administratorCommand {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CareStudioManagerInk.primary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CareStudioManagerInk.field))
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }
                if store.runningTask == current {
                    ToolboxNotice(tone: .info, title: L10n.text("正在运行…", "Running…"))
                }
                if let result = store.results[current] {
                    ToolboxNotice(tone: result.outcome == .succeeded ? .success : .warning,
                                  title: result.message, lines: result.detail,
                                  onDismiss: { store.dismissResult(current) }, showsStateArt: true)
                }
            }
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private func actions(for id: SystemMaintenanceTaskID, status: SystemMaintenanceStatus?) -> some View {
        if case .elsewhere(let destination)? = status?.mode {
            ToolboxLinkButton(title: destination.title, systemImage: "arrow.up.forward.square") {
                if destination == .freeUpMemoryPage { openFreeUpMemory() } else { store.open(destination) }
            }
        }
        if id.administratorCommand != nil {
            ToolboxLinkButton(title: L10n.text("拷贝终端命令", "Copy Terminal Command"), systemImage: "doc.on.doc") {
                store.copyAdministratorCommand(id)
            }
        }
        if status?.needsFullDiskAccess == true {
            ToolboxLinkButton(title: L10n.text("打开“完全磁盘访问权限”", "Open Full Disk Access"),
                              systemImage: "lock.open", action: store.openFullDiskAccessSettings)
        }
    }
}

extension View {
    /// The question before the selected maintenance tasks run, with what each
    /// one does; the maintenance page and Smart Care's Run (D168) ask the
    /// same. Report §4 item 13: the Performance tile asks it about the
    /// recommended tasks it runs (`tasks`).
    func maintenanceRunConfirmation(_ store: SystemMaintenanceStore, tasks: [SystemMaintenanceTaskID]? = nil,
                                    isPresented: Binding<Bool>, run: @escaping () -> Void) -> some View {
        confirmationDialog(tasks == nil ? L10n.text("运行选中的维护任务？", "Run the Selected Maintenance Tasks?")
                                        : L10n.text("运行推荐的维护任务？", "Run the Recommended Maintenance Tasks?"),
                           isPresented: isPresented, titleVisibility: .visible) {
            Button(L10n.text("运行", "Run"), action: run)
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text((tasks ?? store.selectedTasks).map { "\($0.title)：\($0.consequence ?? "")" }.joined(separator: "\n\n"))
        }
    }
}

extension SystemMaintenanceTaskID {
    /// D154 batch 3Q: the task's object in the left column (CleanMyMac gives
    /// every maintenance task its own picture; `图位清单-工具面板左栏`, two
    /// made for it, D166③).
    var art: GeneratedArt {
        switch self {
        case .freeUpMemory: .tileFreeable
        case .purgeableSpace: .tilePurgeable
        case .flushDNS: .tileOtherSources
        case .speedUpMail: .tileMail
        case .rebuildSpotlight: .tileReview
        case .repairPermissions: .tilePermissions
        case .maintenanceScripts: .tileMaintenance
        case .timeMachineSnapshots: .tileHistory
        case .rebuildLaunchServices: .tileSync
        }
    }
}
