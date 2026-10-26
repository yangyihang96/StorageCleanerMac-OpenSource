import AppKit
import SwiftUI

enum LargeFilesViewMode {
    case analysis
    case migration
}

enum StorageAnalysisDisplayMode: String, CaseIterable, Hashable, Identifiable {
    case visualMap
    case columnBrowser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visualMap:
            L10n.text("矩形图", "Blocks")
        case .columnBrowser:
            L10n.text("分栏", "Columns")
        }
    }
}

struct LargeFilesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    @ObservedObject var workspace: LargeFilesStore
    var mode: LargeFilesViewMode = .analysis
    @State private var externalVolumes: [ExternalStorageVolume] = []
    @State private var pendingMigration: ExternalMigrationItem?
    @State private var pendingOriginalRemoval: PendingOriginalRemoval?
    @State private var migratingItemID: String?
    @State private var migrationTask: Task<Void, Never>?
    @State private var migrationActivity: (title: String, detail: String)?
    @State private var migrationNotice: ExternalMigrationNotice?
    @State private var isRefreshingVolumes = false
    private var rawItems: [StorageItem] {
        workspace.items
    }

    private var selectedVolume: ExternalStorageVolume? {
        externalVolumes.first { $0.id == workspace.migrationDestinationVolumeID }
    }

    private var migratableApplications: [ExternalMigrationItem] {
        store.installedApps
            .compactMap(ExternalMigrationItem.application)
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    var body: some View {
        Group {
            if mode == .analysis {
                analysisWorkspace
            } else {
                migrationWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
#if DEBUG
            guard !FeaturePresentationDemo.isEnabled else { return }
#endif
            // N18 review: an original put back from Operation History while
            // another page was open no longer shows as moved.
            workspace.refreshMigrationCompletions()
            if mode == .migration {
                if prepareMigrationPresentationFixtureIfRequested() { return }
                await refreshExternalVolumes()
            }
        }
        .alert(
            L10n.text("确认复制", "Confirm Copy"),
            isPresented: Binding(
                get: { pendingMigration != nil },
                set: { if !$0 { pendingMigration = nil } }
            ),
            presenting: pendingMigration
        ) { item in
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
            Button(L10n.text("复制并验证", "Copy and Verify")) {
                startMigration(item)
            }
        } message: { item in
            Text(migrationConfirmationText(for: item))
        }
        .alert(
            L10n.text("处理原件？", "Handle Original?"),
            isPresented: Binding(
                get: { pendingOriginalRemoval != nil },
                set: { if !$0 { pendingOriginalRemoval = nil } }
            ),
            presenting: pendingOriginalRemoval
        ) { pending in
            Button(L10n.text("保留原件", "Keep Original"), role: .cancel) {}
            Button(L10n.text("移到废纸篓", "Move to Trash"), role: .destructive) {
                moveOriginalToTrash(pending)
            }
        } message: { pending in
            Text(L10n.text(
                "“\(pending.item.title)”的副本已经通过完整性验证。应用会在再次验证副本和原件后，才把原件移到废纸篓。",
                "The copy of “\(pending.item.title)” passed integrity verification. The app will verify the copy and original again before moving the original to Trash."
            ))
        }
    }

    @ViewBuilder
    private var analysisWorkspace: some View {
        FileAnalysisLightfieldView(workspace: workspace)
    }

    private var migrationWorkspace: some View {
        FileMigrationLightfieldView(entries: migrationEntries, volumes: externalVolumes,
            destinationID: $workspace.migrationDestinationVolumeID,
            sourceRoot: workspace.migrationSourcePath ?? FileManager.default.homeDirectoryForCurrentUser.path,
            completions: workspace.migrationCompletions, busyID: migratingItemID,
            refreshing: isRefreshingVolumes, notice: migrationNotice?.message,
            activity: migrationActivity.map { $0.title + " · " + $0.detail },
            onRefresh: { Task { await refreshExternalVolumes() } },
            onRescan: { if workspace.migrationKind == .application { store.refreshInstalledApps() } else { workspace.startScan() } },
            onCancel: { migrationTask?.cancel() }, onCopy: { pendingMigration = $0 },
            onOriginal: { item, completion in
                pendingOriginalRemoval = PendingOriginalRemoval(item: item,
                    destinationURL: completion.destinationURL, volume: completion.volume,
                    contentVerification: completion.contentVerification)
            }, onReveal: { item in
                if let completion = workspace.migrationCompletions[item.id], completion.isMovedAway {
                    ExternalDriveMigrationService.reveal(completion.destinationURL)
                } else { store.reveal(item.sourceURL.path) }
            }, canTrash: { item in
                rawItems.first { ExternalMigrationItem.largeFile($0)?.id == item.id }.map { store.canRequestTrash($0) } ?? false
            }, onTrash: { item in
                if let source = rawItems.first(where: { ExternalMigrationItem.largeFile($0)?.id == item.id }) { store.requestTrash(source) }
            },
            listingNote: workspace.migrationKind == .file ? workspace.listingSummary?.note : nil,
            lowerBoundIDs: lowerBoundMigrationIDs,
            reclaimable: workspace.migrationKind == .file ? migrationReclaimable : [:])
    }

    /// D104 G1：各文件清空废纸篓后预计释放多少，按迁移行 ID。
    private var migrationReclaimable: [String: CleanupReclaimableEstimate] {
        let estimates = workspace.reclaimableEstimates
        guard !estimates.isEmpty else { return [:] }
        return Dictionary(rawItems.compactMap { item in
            guard let estimate = estimates[item.id], let id = ExternalMigrationItem.largeFile(item)?.id else { return nil }
            return (id, estimate)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// D84：测量超时、大小只是本轮量到的下限的行。
    private var lowerBoundMigrationIDs: Set<String> {
        guard let paths = workspace.listingSummary?.lowerBoundPaths, !paths.isEmpty else { return [] }
        return Set(rawItems.compactMap { item in
            paths.contains(PathSafety.normalizedPath(item.path)) ? ExternalMigrationItem.largeFile(item)?.id : nil
        })
    }

    private var migrationEntries: [LightfieldMigrationEntry] {
        if workspace.migrationKind == .application {
            return migratableApplications.map { item in
                LightfieldMigrationEntry(item: item, modifiedAt: store.installedApps.first { $0.path == item.sourceURL.path }?.modifiedAt)
            }
        }
        return LightfieldMigrationPresentation.fileEntries(rawItems)
    }

    private func migrationConfirmationText(for item: ExternalMigrationItem) -> String {
        guard let selectedVolume else { return "" }
        if item.kind == .application {
            return L10n.text(
                "将“\(item.title)”复制到 \(selectedVolume.name) 并验证 App 身份和代码签名。应用迁移仅复制并保留原件，不提供移除原 App；请先完全退出该 App。",
                "Copy “\(item.title)” to \(selectedVolume.name) and verify its identity and code signature. App migration is copy-only and keeps the original. Original-app removal is unavailable. Quit it first."
            )
        }
        return L10n.text(
            "将“\(item.title)”复制到 \(selectedVolume.name) 并完成 SHA-256 内容校验。本步骤不会处理原件，也不会覆盖同名文件。",
            "Copy “\(item.title)” to \(selectedVolume.name) and verify it with SHA-256. This step does not change the original or overwrite an existing item."
        )
    }

    private func prepareMigrationPresentationFixtureIfRequested() -> Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        guard let scenario = DebugExternalMigrationPresentationFixture.launchScenario else {
            return false
        }
        let fixture = DebugExternalMigrationPresentationFixture.fixture
        externalVolumes = [fixture.volume]
        workspace.migrationDestinationVolumeID = fixture.volume.id
        switch scenario {
        case .copy:
            pendingMigration = fixture.item
        case .original:
            workspace.recordMigrationCompletion(ExternalMigrationCompletion(
                destinationURL: fixture.destinationURL,
                volume: fixture.volume,
                didMoveSourceToTrash: false
            ), for: fixture.item.id)
            pendingOriginalRemoval = PendingOriginalRemoval(
                item: fixture.item,
                destinationURL: fixture.destinationURL,
                volume: fixture.volume
            )
        }
        return true
#else
        return false
#endif
    }

    private func refreshExternalVolumes() async {
        guard !isRefreshingVolumes else { return }
        isRefreshingVolumes = true
        let volumes = await Task.detached(priority: .utility) {
            ExternalDriveMigrationService.availableVolumes()
        }.value
        externalVolumes = volumes
        if !volumes.contains(where: { $0.id == workspace.migrationDestinationVolumeID }) {
            workspace.migrationDestinationVolumeID = volumes.first?.id ?? ""
        }
        isRefreshingVolumes = false

        if workspace.migrationKind == .application,
           !volumes.isEmpty,
           !store.hasScannedInstalledApps,
           !store.isLoadingInstalledApps {
            store.refreshInstalledApps(priority: .utility)
        }
    }

    private func startMigration(_ item: ExternalMigrationItem) {
        guard let selectedVolume, migratingItemID == nil else { return }
        pendingMigration = nil
        migrationNotice = nil
        migratingItemID = item.id
        migrationActivity = (
            L10n.text("正在复制并验证", "Copying and Verifying"),
            "\(item.title) → \(selectedVolume.name)"
        )

        migrationTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try ExternalDriveMigrationService.migrate(item, to: selectedVolume)
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                workspace.recordMigrationCompletion(ExternalMigrationCompletion(
                    destinationURL: result.destinationURL,
                    volume: selectedVolume,
                    didMoveSourceToTrash: result.didMoveSourceToTrash,
                    contentVerification: result.contentVerification,
                    information: result.information
                ), for: item.id)
                migrationNotice = ExternalMigrationNotice(
                    message: result.noticeMessage(fallback: L10n.text(
                        "副本已复制并验证，原件仍保留。确认外接硬盘中的副本可正常使用后，再决定是否处理原件。",
                        "The copy was verified and the original remains. Confirm the external copy works before deciding whether to handle the original."
                    )),
                    isError: result.publicationWarning != nil,
                    destinationURL: result.destinationURL
                )
                if item.kind != .application, result.publicationWarning == nil {
                    pendingOriginalRemoval = PendingOriginalRemoval(
                        item: item,
                        destinationURL: result.destinationURL,
                        volume: selectedVolume,
                        contentVerification: result.contentVerification
                    )
                }
                if item.kind == .application {
                    store.refreshInstalledApps(priority: .utility)
                }
                if !Task.isCancelled { await refreshExternalVolumes() }
            } catch is CancellationError {
                migrationNotice = ExternalMigrationNotice(
                    message: L10n.text("已取消等待，原件保留；未完成的副本不会发布，临时文件将在复制返回后清理。", "Waiting was cancelled. The original was kept. The unfinished copy will not be published; temporary files will be cleaned up when copying returns."),
                    isError: false, destinationURL: nil
                )
            } catch {
                migrationNotice = ExternalMigrationNotice(
                    message: FileContentReadError.userMessage(for: error),
                    isError: true,
                    destinationURL: nil
                )
            }
            migratingItemID = nil
            migrationActivity = nil
            migrationTask = nil
        }
    }

    private func moveOriginalToTrash(_ pending: PendingOriginalRemoval) {
        guard migratingItemID == nil, pending.item.kind != .application else { return }
        pendingOriginalRemoval = nil
        migrationNotice = nil
        migratingItemID = pending.item.id
        migrationActivity = (
            L10n.text("正在核验副本并处理原件", "Verifying Copy and Handling Original"),
            pending.item.title
        )

        migrationTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try ExternalDriveMigrationService.moveOriginalToTrash(
                        pending.item,
                        verifiedCopyAt: pending.destinationURL,
                        on: pending.volume,
                        contentVerification: pending.contentVerification
                    )
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                workspace.recordMigrationCompletion(ExternalMigrationCompletion(
                    destinationURL: result.destinationURL,
                    volume: pending.volume,
                    didMoveSourceToTrash: result.didMoveSourceToTrash,
                    originalPath: pending.item.sourceURL.path,
                    originalIdentity: result.originalIdentity,
                    information: result.information
                ), for: pending.item.id)
                // N18: the move has a receipt in Operation History.
                migrationNotice = ExternalMigrationNotice(
                    message: result.noticeMessage(fallback: result.canRestoreFromHistory
                        ? L10n.text(
                            "已再次验证副本；原件已移到废纸篓，可在“操作记录”中恢复到原处。清空废纸篓后才会释放空间。",
                            "The copy was verified again and the original moved to Trash. Operation History can put it back. Empty Trash to reclaim space."
                        )
                        : L10n.text(
                            "已再次验证副本；原件已不在原处，但操作记录需要核实。请在“操作记录”中刷新后查看。",
                            "The copy was verified again and the original is no longer in place, but its record needs checking. Refresh Operation History to review it."
                        )),
                    isError: !result.canRestoreFromHistory,
                    destinationURL: result.destinationURL
                )
                if pending.item.kind == .application {
                    store.refreshInstalledApps(priority: .utility)
                }
                if !Task.isCancelled { await refreshExternalVolumes() }
            } catch is CancellationError {
                migrationNotice = ExternalMigrationNotice(
                    message: L10n.text("已取消处理原件，原件和已验证的副本均保留。", "Handling the original was cancelled. Both the original and the verified copy were kept."),
                    isError: false, destinationURL: nil
                )
            } catch {
                migrationNotice = ExternalMigrationNotice(
                    message: FileContentReadError.userMessage(for: error),
                    isError: true,
                    destinationURL: pending.destinationURL
                )
            }
            migratingItemID = nil
            migrationActivity = nil
            migrationTask = nil
        }
    }


}

/// D70 single-column choices; the feature Store retains real scope identities.
struct StorageAnalysisScopePicker: View {
    let targets: [StorageMapScanTarget]
    @Binding var selectedID: String
    let isDisabled: Bool
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                LightfieldOptionRow(title: target.title, icon: FileLightfieldPresentation.scopeIcon(target.kind), module: .largeFiles,
                    selection: Binding(get: { selectedID == target.id }, set: { if $0 { selectedID = target.id } }),
                    metadata: target.path, probeID: "fileAnalysis.scope.\(index)")
                    .disabled(isDisabled).help(target.path)
            }
        }.lightfieldComponentProbe("fileAnalysis.scopes")
            .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("分析范围", "Analysis Scope"))
    }
}

struct LargeFilesScanLandingView: View {
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isPresentationFixture
#endif
    @Environment(\.windowLayoutMetrics) private var layout
    @ObservedObject var store: ScanStore
    @ObservedObject var workspace: LargeFilesStore
    var mode: LargeFilesViewMode = .analysis
    @State private var externalVolumes: [ExternalStorageVolume] = []
    @State private var isRefreshingVolumes = false

    private var status: ScanStatusPresentation {
        if mode == .migration, workspace.migrationKind == .application {
            if store.isLoadingInstalledApps {
                return .scanning(L10n.text("正在读取可搬移 App…", "Reading movable apps…"))
            }
            if store.hasScannedInstalledApps {
                let count = store.installedApps.compactMap(ExternalMigrationItem.application).count
                return .completed(L10n.text("已找到 \(ByteFormat.count(count)) 个可搬移 App", "Found \(ByteFormat.count(count)) movable apps"))
            }
            return .neverScanned
        }

        return switch mode == .migration ? workspace.phase : workspace.storageAnalysisPhase {
        case .idle:
            mode == .migration
                ? .neverScanned
                : .idle(L10n.text("尚未分析磁盘空间", "Disk space not analyzed"))
        case .scanning, .paused, .cancelling:
            .scanning(scanningStatusText)
        case .finished:
            .completed(
                mode == .migration
                    ? L10n.text(
                        "已找到 \(workspace.items.compactMap(ExternalMigrationItem.largeFile).count) 个可搬移候选",
                        "Found \(workspace.items.compactMap(ExternalMigrationItem.largeFile).count) movable candidates"
                    )
                    : workspace.storageAnalysis.map {
                        L10n.text(
                            "已索引 \($0.inspectedItemCount) 项 · \(ByteFormat.storageString($0.rootSnapshot.measuredBytes))",
                            "Indexed \($0.inspectedItemCount) items · \(ByteFormat.storageString($0.rootSnapshot.measuredBytes))"
                        )
                    } ?? L10n.text("分析完成", "Analysis Complete")
            )
        case .failed:
            .failed(
                (mode == .migration
                    ? workspace.errorMessage
                    : workspace.storageAnalysisErrorMessage)
                    ?? L10n.text("扫描失败", "Scan failed")
            )
        case .cancelled:
            .failed(L10n.text("扫描已取消，保留上次结果", "Scan cancelled; previous results were kept"))
        }
    }

    var body: some View {
        Group {
        if isLoading {
            runtimePage
        } else {
        FeatureLightfieldPage(module: route, phase: .landing, title: route.sidebarTitle,
            status: status.title, safety: trustText, actionTitle: scanActionTitle,
            actionEnabled: canStart, action: startSelectedScan) {
            FeatureLightfieldOptions(title: mode == .migration ? L10n.text("读取范围", "Read Scope") : L10n.text("分析范围", "Analysis Scope")) {
                if mode == .analysis { storageTargetPicker }
                else { migrationConfiguration }
            }
        }
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .featureFlowTransition(value: isLoading)
        .task {
#if DEBUG
            guard !FeaturePresentationDemo.isEnabled, !isPresentationFixture else { return }
#endif
            if mode == .migration {
                await refreshExternalVolumes()
            }
        }
    }

    private var route: ReviewFilter {
        mode == .migration ? .migration : .largeFiles
    }

    private var scanActionTitle: String {
        if mode == .migration {
            if workspace.migrationKind == .application {
                return store.hasScannedInstalledApps
                    ? L10n.text("重新扫描可搬移 App", "Rescan Movable Apps")
                    : L10n.text("扫描可搬移 App", "Scan Movable Apps")
            }
            return workspace.hasScanned
                ? L10n.text("重新扫描可搬移文件", "Rescan Movable Files")
                : L10n.text("扫描可搬移文件", "Scan Movable Files")
        }
        return workspace.hasStorageAnalysis
            ? L10n.text("重新分析磁盘", "Rescan Disk")
            : L10n.text("分析磁盘空间", "Analyze Disk Space")
    }

    private var scanActionDetail: String { "" }

    private var trustText: String {
        mode == .migration
            ? L10n.text(
                "只读扫描 · 先复制并验证，另行确认后原件才会移到废纸篓",
                "Read-only scan · Copy and verify first; originals move to Trash only after a separate confirmation"
            )
            : L10n.text(
                "只读分析 · 不会自动打开访达，也不会删除或修改文件",
                "Read-only analysis · Never opens Finder or changes files automatically"
            )
    }

    private var hasResult: Bool {
        if mode == .migration, workspace.migrationKind == .application {
            return store.hasScannedInstalledApps
        }
        return mode == .migration ? workspace.hasScanned : workspace.hasStorageAnalysis
    }

    private var isLoading: Bool {
        if mode == .migration, workspace.migrationKind == .application {
            return store.isLoadingInstalledApps
        }
        return mode == .migration ? workspace.isScanning : workspace.isAnalyzingStorage
    }

    private var canStart: Bool {
        if mode == .migration, workspace.migrationKind == .application {
            return store.canRefreshInstalledApps
        }
        return mode == .migration ? workspace.canScan : workspace.canStartStorageAnalysis
    }

    private var scanningStatusText: String {
        mode == .migration
            ? L10n.text("正在扫描可搬移文件…", "Scanning movable files…")
            : L10n.text("正在建立目录索引…", "Building directory index…")
    }

    private var storageTargetPicker: some View {
        StorageAnalysisScopePicker(
            targets: presentationStorageMapTargets,
            selectedID: presentationStorageMapSelection,
            isDisabled: isLoading
        )
    }

    private var presentationStorageMapSelection: Binding<String> {
        Binding(get: {
#if DEBUG
            if isPresentationFixture { return presentationStorageMapTargets[0].id }
#endif
            return workspace.selectedStorageMapTargetID
        }, set: { value in
#if DEBUG
            guard !isPresentationFixture else { return }
#endif
            workspace.selectedStorageMapTargetID = value
        })
    }

    private var presentationStorageMapTargets: [StorageMapScanTarget] {
#if DEBUG
        if isPresentationFixture {
            return [StorageMapScanTarget(path: "/Fixture/Disk", title: L10n.text("演示磁盘", "Fixture Disk"), kind: .internalVolume),
                    StorageMapScanTarget(path: "/Fixture/Home", title: L10n.text("演示个人目录", "Fixture Home"), kind: .homeDirectory)]
        }
#endif
        return workspace.storageMapTargets
    }

    private var migrationConfiguration: some View {
        VStack(alignment: .leading, spacing: 0) {
            LightfieldOptionRow(title: L10n.text("可搬移大文件", "Movable Large Files"), icon: .migrationDocuments, module: .migration,
                selection: Binding(get: { workspace.migrationKind == .file }, set: { if $0 { workspace.migrationKind = .file } }))
            LightfieldOptionRow(title: L10n.text("可搬移应用", "Movable Apps"), icon: .migrationApplication, module: .migration,
                selection: Binding(get: { workspace.migrationKind == .application }, set: { if $0 { workspace.migrationKind = .application } }))
            if workspace.migrationKind == .file { largeFileThresholdControl }
            migrationSourceControl
            migrationDestinationControl
        }
    }

    /// D85：大文件门槛三档；默认 200 MiB，单位按二进制写明。
    private var largeFileThresholdControl: some View {
        HStack(spacing: 8) {
            LightfieldOptionIconView(icon: .migrationItemType)
            Text(L10n.text("大文件门槛", "Large File Threshold")).font(.system(size: 13)).lineLimit(1)
            LightfieldTextSegments(titles: LargeFileThreshold.allCases.map(\.title),
                selection: Binding(get: { LargeFileThreshold.allCases.firstIndex(of: workspace.largeFileThreshold) ?? 1 },
                    set: { index in
                        guard LargeFileThreshold.allCases.indices.contains(index) else { return }
                        workspace.largeFileThreshold = LargeFileThreshold.allCases[index]
                    }),
                module: .migration, spacing: 18)
                .disabled(isLoading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
        .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
        .help(workspace.largeFileThreshold.detail + "\n" + LargeFileThreshold.unitHelp)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("大文件门槛", "Large File Threshold"))
        .lightfieldComponentProbe("migration.threshold")
    }

    // Titled rows like the threshold row. A borderless Menu flattens a custom
    // label to its text and a chevron, so the icon, title, row height,
    // hairline and free-space bar sit outside it and the menu shows the value.
    private var migrationSourceControl: some View {
        HStack(spacing: 8) {
            LightfieldOptionIconView(icon: .migrationSourceFolder)
            Text(L10n.text("来源", "Source")).font(.system(size: 13)).lineLimit(1)
            Menu {
                Button(L10n.text("用户可访问的文件夹", "User-accessible folders")) {
                    workspace.selectMigrationSource(nil)
                }
                Divider()
                Button(L10n.text("选择文件夹…", "Choose Folder…")) { chooseMigrationSource() }
            } label: {
                Text(migrationSourceName).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(L10n.text("来源", "Source"))
            .accessibilityValue(workspace.migrationSourcePath ?? L10n.text("用户可访问的文件夹", "User-accessible folders"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
        .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
        .help(workspace.migrationSourcePath ?? L10n.text("用户可访问的文件夹", "User-accessible folders"))
        .lightfieldComponentProbe("migration.source")
    }

    /// A chosen folder by its name; the full path is the row's help.
    private var migrationSourceName: String {
        workspace.migrationSourcePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? L10n.text("用户可访问的文件夹", "User-accessible folders")
    }

    private var migrationDestinationControl: some View {
        HStack(spacing: 8) {
            LightfieldOptionIconView(icon: .migrationDestinationDrive)
            Text(L10n.text("目标位置", "Destination")).font(.system(size: 13)).lineLimit(1)
            Menu {
                if presentationExternalVolumes.isEmpty {
                    Text(L10n.text("未连接可写的物理外接硬盘", "No writable physical external drive"))
                } else {
                    ForEach(presentationExternalVolumes) { volume in
                        // D97: the same decimal unit as the row's own free space.
                        Button("\(volume.name) · \(ByteFormat.storageString(volume.availableBytes))") {
                            workspace.migrationDestinationVolumeID = volume.id
                        }
                    }
                }
                Divider()
                Button(L10n.text("刷新外接设备", "Refresh External Drives")) {
                    Task { await refreshExternalVolumes() }
                }
            } label: {
                Text(selectedVolume?.name ?? L10n.text("未连接可写的物理外接硬盘", "No writable physical external drive"))
                    .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(isRefreshingVolumes)
            .accessibilityLabel(L10n.text("目标位置", "Destination"))
            .accessibilityValue(selectedVolume?.url.path ?? L10n.text("未连接可写的物理外接硬盘", "No writable physical external drive"))
            Spacer(minLength: 8)
            if let volume = selectedVolume {
                LightfieldDataBar(progress: volume.totalBytes > 0 ? Double(volume.availableBytes) / Double(volume.totalBytes) : nil,
                    module: .migration, style: .share, accessibilityLabel: L10n.text("目标盘可用比例", "Destination Free Share"))
                    .frame(width: 88)
            }
            Text(selectedVolume.map { ByteFormat.storageString($0.availableBytes) } ?? "—")
                .font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
        .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
        .help(selectedVolume?.url.path ?? L10n.text("请连接外接硬盘", "Connect an external drive"))
        .lightfieldComponentProbe("migration.destination")
    }

    private var selectedVolume: ExternalStorageVolume? {
#if DEBUG
        if isPresentationFixture { return presentationExternalVolumes.first }
#endif
        return presentationExternalVolumes.first { $0.id == workspace.migrationDestinationVolumeID }
    }

    private var presentationExternalVolumes: [ExternalStorageVolume] {
#if DEBUG
        if isPresentationFixture { return [FeatureLightfieldFileResultFixture.volume] }
#endif
        return externalVolumes
    }

    private func chooseMigrationSource() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择要迁移的文件夹", "Choose a Folder to Migrate")
        panel.prompt = L10n.text("选择", "Choose")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !workspace.selectMigrationSource(url) {
            NSSound.beep()
        }
    }

    @MainActor
    private func refreshExternalVolumes() async {
        guard !isRefreshingVolumes else { return }
        isRefreshingVolumes = true
        let volumes = await Task.detached(priority: .utility) {
            ExternalDriveMigrationService.availableVolumes()
        }.value
        externalVolumes = volumes
        if !volumes.contains(where: { $0.id == workspace.migrationDestinationVolumeID }) {
            workspace.migrationDestinationVolumeID = volumes.first?.id ?? ""
        }
        isRefreshingVolumes = false
    }

    private var runtimePage: some View {
        let phase = mode == .migration ? workspace.phase : workspace.storageAnalysisPhase
        let state: RuntimeWorkflowState = phase == .paused ? .paused : phase == .cancelling ? .stopping : .running
        let readingApplications = mode == .migration && workspace.migrationKind == .application
        return LargeFilesRunningPage(module: route,
            title: readingApplications ? L10n.text("正在读取可搬移应用", "Reading Movable Applications")
                : mode == .migration ? L10n.text("正在扫描可搬移文件", "Scanning Movable Files")
                : L10n.text("正在分析磁盘空间", "Analyzing Disk Space"),
            state: state,
            fraction: mode == .migration && !readingApplications ? workspace.progress.flatMap {
                $0.progressKind == .determinate ? Double($0.fractionCompleted) : nil
            } : nil,
            metrics: runtimeMetrics,
            currentItem: mode == .migration ? workspace.progress?.currentPath : workspace.storageAnalysisProgress?.currentPath,
            trustText: trustText, canCancel: !readingApplications && state != .stopping,
            onCancel: readingApplications ? nil : {
                if mode == .migration { workspace.cancelScan() }
                else { workspace.cancelStorageAnalysis() }
            })
    }

    private var runtimeMetrics: [RuntimeWorkflowMetric] {
        if mode == .migration {
            guard workspace.migrationKind != .application, let progress = workspace.progress else { return [] }
            return [
                .init(title: L10n.text("已发现", "Items Found"), value: L10n.items(progress.discoveredItemCount)),
                // D97: the migration results list sizes in the same decimal unit.
                .init(title: L10n.text("候选大小", "Candidate Size"), value: ByteFormat.storageString(progress.discoveredBytes))
            ]
        }
        guard let progress = workspace.storageAnalysisProgress else { return [] }
        return [
            .init(title: L10n.text("已读取", "Items Read"), value: L10n.items(progress.inspectedItemCount)),
            .init(title: L10n.text("已测量大小", "Measured Size"), value: ByteFormat.storageString(progress.measuredBytes))
        ]
    }

    private var cancelScanButton: some View {
        Button(role: .cancel) {
            if mode == .migration {
                workspace.cancelScan()
            } else {
                workspace.cancelStorageAnalysis()
            }
        } label: {
            Label(L10n.text("取消", "Cancel"), systemImage: "xmark")
        }
        .appButtonChrome(.secondary)
    }

    private func startSelectedScan() {
        if mode == .migration {
            if workspace.migrationKind == .application {
                store.refreshInstalledApps()
            } else {
                workspace.startScan()
            }
        } else {
            workspace.startStorageAnalysis()
        }
    }
}

private struct ExternalMigrationNotice: Equatable {
    let message: String
    let isError: Bool
    let destinationURL: URL?
}

private struct PendingOriginalRemoval: Equatable, Sendable {
    let item: ExternalMigrationItem
    let destinationURL: URL
    let volume: ExternalStorageVolume
    var contentVerification: MigrationContentVerification? = nil
}

#if DEBUG || STORAGE_CLEANER_BETA
enum DebugExternalMigrationPresentationFixture {
    static let launchArgument = "--debug-migration-confirmation"

    enum Scenario: String, Sendable {
        case copy
        case original
    }

    struct Fixture: Sendable {
        let item: ExternalMigrationItem
        let volume: ExternalStorageVolume
        let destinationURL: URL
    }

    static func scenario(arguments: [String]) -> Scenario? {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else { return nil }
        return Scenario(rawValue: arguments[index + 1])
    }

    static var launchScenario: Scenario? {
        scenario(arguments: ProcessInfo.processInfo.arguments)
    }

    static let fixture: Fixture = {
        let volumeURL = URL(fileURLWithPath: "/Volumes/Debug External", isDirectory: true)
        let sourceURL = URL(fileURLWithPath: "/DebugFixture/Archive.mov")
        let volume = ExternalStorageVolume(
            url: volumeURL,
            name: "Debug External",
            availableBytes: 500_000_000_000,
            totalBytes: 1_000_000_000_000,
            fileSystem: "APFS",
            supportsApplications: true
        )
        let item = ExternalMigrationItem(
            id: "debug:file:archive",
            title: "Archive.mov",
            sourceURL: sourceURL,
            sizeBytes: 12_800_000_000,
            kind: .file,
            bundleIdentifier: ""
        )
        return Fixture(
            item: item,
            volume: volume,
            destinationURL: volumeURL
                .appendingPathComponent("StorageCleaner Migration/Large Files/Archive.mov")
        )
    }()
}
#endif

/// The scan/analysis presentation used by the workspace and inert captures.
struct LargeFilesRunningPage: View {
    let module: ReviewFilter
    let title: String
    var state: RuntimeWorkflowState = .running
    var fraction: Double? = nil
    var metrics: [RuntimeWorkflowMetric] = []
    var currentItem: String? = nil
    let trustText: String
    let canCancel: Bool
    let onCancel: (() -> Void)?
    var body: some View {
        FeatureRuntimePage(module: module, title: title, state: state,
            fraction: fraction, metrics: metrics, currentItem: currentItem, trustText: trustText,
            canCancel: canCancel, cancelTitle: L10n.text("取消扫描", "Cancel Scan"), onCancel: onCancel
        ) { EmptyView() } actions: { EmptyView() }
    }
}
