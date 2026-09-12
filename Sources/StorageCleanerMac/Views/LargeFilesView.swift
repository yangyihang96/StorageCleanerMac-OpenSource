import AppKit
import SwiftUI

enum LargeFilesViewMode {
    case analysis
    case migration
}

enum StorageAnalysisDisplayMode: String, CaseIterable, Hashable, Identifiable {
    case visualMap
    case sunburstMap
    case columnBrowser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visualMap:
            L10n.text("矩形图", "Blocks")
        case .sunburstMap:
            L10n.text("旭日图", "Sunburst")
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
    @State private var completedMigrations: [String: ExternalMigrationCompletion] = [:]
    @State private var migrationNotice: ExternalMigrationNotice?
    @State private var isRefreshingVolumes = false
    @AppStorage("storage-analysis.display-mode")
    private var analysisSurfaceRawValue = StorageAnalysisDisplayMode.visualMap.rawValue

    private var analysisSurface: StorageAnalysisDisplayMode {
        StorageAnalysisDisplayMode(rawValue: analysisSurfaceRawValue) ?? .visualMap
    }

    private var analysisSurfaceSelection: Binding<StorageAnalysisDisplayMode> {
        Binding(
            get: { analysisSurface },
            set: { analysisSurfaceRawValue = $0.rawValue }
        )
    }

    private var rawItems: [StorageItem] {
        workspace.items
    }

    private var visibleItems: [StorageItem] {
        rawItems
            .filter { ExternalMigrationItem.largeFile($0) != nil }
            .sorted {
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private var selectedVolume: ExternalStorageVolume? {
        externalVolumes.first { $0.id == workspace.migrationDestinationVolumeID }
    }

    private var migratableFiles: [ExternalMigrationItem] {
        rawItems.compactMap(ExternalMigrationItem.largeFile)
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
        if !workspace.hasStorageAnalysis {
            ScrollView {
                AppEmptyState(
                    title: L10n.text("尚未建立磁盘空间索引", "Disk Space Has Not Been Indexed"),
                    detail: L10n.text("重新分析后可按层级浏览每个文件夹", "Analyze again to browse every folder by level"),
                    systemImage: "internaldrive"
                )
                    .padding(AppDesignTokens.Layout.pagePadding)
                    .appMotionEntrance(delay: 0.075)
            }
        } else {
            VStack(spacing: 0) {
                analysisToolbar
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)
                Divider()

                switch analysisSurface {
                case .visualMap, .sunburstMap, .columnBrowser:
                    LargeFileStorageMap(
                        workspace: workspace,
                        displayMode: analysisSurface
                    )
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .layoutPriority(1)
                    .clipped()
                    .transition(AppMotionTokens.listTransition(reduceMotion: reduceMotion))
                }
            }
            .animation(
                AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
                value: analysisSurface
            )
        }
    }

    private var analysisToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppDesignTokens.Spacing.large) {
                analysisResultIdentity
                    .layoutPriority(1)
                Spacer(minLength: AppDesignTokens.Spacing.large)
                analysisToolbarControls
            }

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                analysisResultIdentity
                analysisToolbarControls
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, AppDesignTokens.Spacing.small)
    }

    private var analysisToolbarControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                analysisScopeMenu
                analysisSurfacePicker
            }

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                analysisScopeMenu
                analysisSurfacePicker
            }
        }
    }

    private var analysisResultIdentity: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
                analysisScopeIdentity
                if let analysis = workspace.storageAnalysis {
                    Text("\(capacitySummary(analysis)) · \(indexedSummary(analysis))")
                        .font(AppDesignTokens.Typography.metadata)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
                analysisScopeIdentity
                if let analysis = workspace.storageAnalysis {
                    Text(capacitySummary(analysis))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(indexedSummary(analysis))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .font(AppDesignTokens.Typography.compactLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var analysisScopeIdentity: some View {
        Label {
            Text(workspace.storageAnalysis?.target.title ?? L10n.text("磁盘空间", "Disk Space"))
                .font(AppDesignTokens.Typography.inlineTitle)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: workspace.storageAnalysis?.target.systemImage ?? "internaldrive.fill")
                .foregroundStyle(AppDesignTokens.Palette.storage)
        }
    }

    private func capacitySummary(_ analysis: StorageMapAnalysisResult) -> String {
        L10n.text(
            "可用 \(ByteFormat.storageString(analysis.volumeAvailableBytes)) / 共 \(ByteFormat.storageString(analysis.volumeTotalBytes))",
            "\(ByteFormat.storageString(analysis.volumeAvailableBytes)) available / \(ByteFormat.storageString(analysis.volumeTotalBytes)) total"
        )
    }

    private func indexedSummary(_ analysis: StorageMapAnalysisResult) -> String {
        L10n.text(
            "已索引 \(analysis.inspectedItemCount) 项",
            "\(analysis.inspectedItemCount) items indexed"
        )
    }

    private var analysisSurfacePicker: some View {
        Picker(L10n.text("显示方式", "View"), selection: analysisSurfaceSelection) {
            ForEach(StorageAnalysisDisplayMode.allCases) { surface in
                Text(surface.title).tag(surface)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 228)
        .accessibilityLabel(L10n.text("显示方式", "View"))
    }

    private var analysisScopeMenu: some View {
        Menu {
            ForEach(workspace.storageMapTargets) { target in
                Button {
                    workspace.selectedStorageMapTargetID = target.id
                    workspace.startStorageAnalysis()
                } label: {
                    Label(target.title, systemImage: target.systemImage)
                }
            }
        } label: {
            Label(L10n.text("更换范围", "Change Scope"), systemImage: "externaldrive.badge.plus")
        }
        .appButtonChrome(.secondary)
        .disabled(!workspace.canStartStorageAnalysis)
        .help(L10n.text("选择另一个磁盘或个人目录并重新分析", "Analyze another disk or the home folder"))
    }

    private var migrationWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
                externalMigrationPanel
                    .appMotionEntrance(delay: 0.055)

                if rawItems.isEmpty || visibleItems.isEmpty {
                    if workspace.migrationKind == .file {
                        emptyPanel(density: .workspace)
                            .appMotionEntrance(delay: 0.075)
                    }
                } else if workspace.migrationKind == .file {
                    Label(
                        L10n.text("可搬移文件", "Files Ready to Move"),
                        systemImage: "doc.on.doc"
                    )
                    .font(AppDesignTokens.Typography.cardTitle)
                    .foregroundStyle(AppDesignTokens.Palette.storage)
                    .accessibilityAddTraits(.isHeader)

                    resultRows
                }
            }
            .padding(AppDesignTokens.Layout.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resultRows: some View {
        LazyVStack(spacing: 8) {
            ForEach(visibleItems) { item in
                let migrationItem = mode == .migration && selectedVolume != nil
                    ? ExternalMigrationItem.largeFile(item)
                    : nil
                LargeFileRow(
                    item: item,
                    store: store,
                    migrationItem: migrationItem,
                    isMigrating: migratingItemID == migrationItem?.id,
                    isMigrationDisabled: migratingItemID != nil,
                    completedMigration: migrationItem.flatMap {
                        completedMigrations[$0.id]
                    },
                    onMigrate: { pendingMigration = $0 },
                    onHandleOriginal: { item, completion in
                        pendingOriginalRemoval = PendingOriginalRemoval(
                            item: item,
                            destinationURL: completion.destinationURL,
                            volume: completion.volume
                        )
                    }
                )
                .transition(AppMotionTokens.listTransition(reduceMotion: reduceMotion))
            }
        }
        .animation(
            AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
            value: workspace.selectedFilter
        )
        .animation(
            AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
            value: workspace.sortMode
        )
        .animation(
            AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
            value: rawItems.map(\.id)
        )
        .appMotionEntrance(delay: 0.10)
    }

    private var externalMigrationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(L10n.text("外接硬盘迁移助手", "External Drive Migration"), systemImage: "externaldrive.badge.plus")
                    .font(AppDesignTokens.Typography.cardTitle)
                Spacer()
                Button {
                    Task { await refreshExternalVolumes() }
                } label: {
                    if isRefreshingVolumes {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(L10n.text("刷新硬盘", "Refresh Drives"), systemImage: "arrow.clockwise")
                    }
                }
                .appButtonChrome(.secondary)
                .disabled(isRefreshingVolumes || migratingItemID != nil)
            }

            if externalVolumes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        L10n.text("未连接可写的物理外接硬盘", "No Writable Physical External Drive"),
                        systemImage: "externaldrive.badge.questionmark"
                    )
                    .font(AppDesignTokens.Typography.inlineTitle)
                    Text(
                        L10n.text(
                            "连接外接硬盘后点“刷新硬盘”。只读镜像、网络卷和虚拟磁盘不会作为迁移目标。",
                            "Connect an external drive, then choose Refresh Drives. Read-only images, network volumes, and virtual disks are excluded."
                        )
                    )
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                }
            } else if let selectedVolume {
                Picker(
                    L10n.text("目标硬盘", "Destination Drive"),
                    selection: $workspace.migrationDestinationVolumeID
                ) {
                    ForEach(externalVolumes) { volume in
                        Text("\(volume.name) · \(ByteFormat.string(volume.availableBytes))")
                            .tag(volume.id)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 8) {
                    MetadataPill(
                        text: L10n.text("可用 \(ByteFormat.string(selectedVolume.availableBytes))", "\(ByteFormat.string(selectedVolume.availableBytes)) available"),
                        systemImage: "externaldrive.fill",
                        tint: AppDesignTokens.Palette.storage
                    )
                    MetadataPill(
                        text: selectedVolume.fileSystem,
                        systemImage: "internaldrive",
                        tint: selectedVolume.supportsApplications
                            ? AppDesignTokens.Palette.success
                            : AppDesignTokens.Palette.warning
                    )
                    MetadataPill(
                        text: L10n.text("可迁移文件 \(migratableFiles.count)", "\(migratableFiles.count) files eligible"),
                        systemImage: "doc.fill",
                        tint: AppDesignTokens.Palette.information
                    )
                }

                Text(
                    L10n.text(
                        "先复制并验证；确认副本可用后，再单独决定是否把原件移到废纸篓。",
                        "Copy and verify first. After confirming the copy, separately decide whether to move the original to Trash."
                    )
                )
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if workspace.migrationKind == .application {
                    Divider()
                    applicationMigrationSuggestions(for: selectedVolume)
                }
            }

            if let migrationNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: migrationNotice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(migrationNotice.isError ? AppDesignTokens.Palette.warning : AppDesignTokens.Palette.success)
                    Text(migrationNotice.message)
                        .font(AppDesignTokens.Typography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let destinationURL = migrationNotice.destinationURL {
                        Button(L10n.text("在访达中显示", "Show in Finder")) {
                            ExternalDriveMigrationService.reveal(destinationURL)
                        }
                        .appButtonChrome(.secondary)
                    }
                }
            }
        }
        .padding(AppDesignTokens.Spacing.large)
        .fullBleedSection()
    }

    @ViewBuilder
    private func applicationMigrationSuggestions(for volume: ExternalStorageVolume) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text("大型 App 建议", "Large App Suggestions"), systemImage: "app.badge")
                .font(AppDesignTokens.Typography.cardTitle)

            if !volume.supportsApplications {
                Text(
                    L10n.text(
                        "此硬盘适合普通文件；搬移 App 请使用 APFS。",
                        "This drive suits regular files; use APFS to move apps."
                    )
                )
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
            } else if store.isLoadingInstalledApps {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("正在读取大型第三方 App…", "Reading large third-party apps…"))
                        .foregroundStyle(.secondary)
                }
            } else if migratableApplications.isEmpty {
                Text(
                    L10n.text(
                        "没有发现超过 1 GB、未运行且可安全建议迁移的第三方 App。",
                        "No third-party app over 1 GB is currently eligible for a safe migration suggestion."
                    )
                )
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
            } else {
                ForEach(migratableApplications) { item in
                    ExternalAppMigrationRow(
                        item: item,
                        isMigrating: migratingItemID == item.id,
                        completedMigration: completedMigrations[item.id],
                        isDisabled: migratingItemID != nil,
                        onMigrate: { pendingMigration = item },
                        onHandleOriginal: { completion in
                            pendingOriginalRemoval = PendingOriginalRemoval(
                                item: item,
                                destinationURL: completion.destinationURL,
                                volume: completion.volume
                            )
                        }
                    )
                }
                Text(
                    L10n.text(
                        "仅迁移 App 本体；账户、项目、缓存与 Application Support 数据仍保留在内置磁盘。部分 App 的自动更新可能要求重新选择安装位置。",
                        "Only the app bundle is migrated. Accounts, projects, caches, and Application Support data stay on the internal disk. Some updaters may require the install location to be selected again."
                    )
                )
                .font(AppDesignTokens.Typography.compactLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func migrationConfirmationText(for item: ExternalMigrationItem) -> String {
        guard let selectedVolume else { return "" }
        if item.kind == .application {
            return L10n.text(
                "将“\(item.title)”复制到 \(selectedVolume.name) 并验证 App 身份和代码签名。本步骤不会处理原 App；请先完全退出该 App。",
                "Copy “\(item.title)” to \(selectedVolume.name) and verify its identity and code signature. This step does not change the original app. Quit it first."
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
            completedMigrations[fixture.item.id] = ExternalMigrationCompletion(
                destinationURL: fixture.destinationURL,
                volume: fixture.volume,
                didMoveSourceToTrash: false
            )
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

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ExternalDriveMigrationService.migrate(item, to: selectedVolume)
                }.value
                completedMigrations[item.id] = ExternalMigrationCompletion(
                    destinationURL: result.destinationURL,
                    volume: selectedVolume,
                    didMoveSourceToTrash: result.didMoveSourceToTrash
                )
                migrationNotice = ExternalMigrationNotice(
                    message: L10n.text(
                        "副本已复制并验证，原件仍保留。确认外接硬盘中的副本可正常使用后，再决定是否处理原件。",
                        "The copy was verified and the original remains. Confirm the external copy works before deciding whether to handle the original."
                    ),
                    isError: false,
                    destinationURL: result.destinationURL
                )
                pendingOriginalRemoval = PendingOriginalRemoval(
                    item: item,
                    destinationURL: result.destinationURL,
                    volume: selectedVolume
                )
                if item.kind == .application {
                    store.refreshInstalledApps(priority: .utility)
                }
                await refreshExternalVolumes()
            } catch {
                migrationNotice = ExternalMigrationNotice(
                    message: error.localizedDescription,
                    isError: true,
                    destinationURL: nil
                )
            }
            migratingItemID = nil
        }
    }

    private func moveOriginalToTrash(_ pending: PendingOriginalRemoval) {
        guard migratingItemID == nil else { return }
        pendingOriginalRemoval = nil
        migrationNotice = nil
        migratingItemID = pending.item.id

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ExternalDriveMigrationService.moveOriginalToTrash(
                        pending.item,
                        verifiedCopyAt: pending.destinationURL,
                        on: pending.volume
                    )
                }.value
                completedMigrations[pending.item.id] = ExternalMigrationCompletion(
                    destinationURL: result.destinationURL,
                    volume: pending.volume,
                    didMoveSourceToTrash: result.didMoveSourceToTrash
                )
                migrationNotice = ExternalMigrationNotice(
                    message: L10n.text(
                        "已再次验证副本；原件已移到废纸篓。清空废纸篓后才会释放空间。",
                        "The copy was verified again and the original moved to Trash. Empty Trash to reclaim space."
                    ),
                    isError: false,
                    destinationURL: result.destinationURL
                )
                if pending.item.kind == .application {
                    store.refreshInstalledApps(priority: .utility)
                }
                await refreshExternalVolumes()
            } catch {
                migrationNotice = ExternalMigrationNotice(
                    message: error.localizedDescription,
                    isError: true,
                    destinationURL: pending.destinationURL
                )
            }
            migratingItemID = nil
        }
    }

    private func emptyPanel(density: AppEmptyStateDensity) -> some View {
        AppEmptyState(
            title: emptyStateTitle,
            detail: emptyStateDetail,
            systemImage: mode == .migration ? "externaldrive.badge.questionmark" : rawItems.isEmpty ? "checkmark.circle" : "magnifyingglass",
            density: density
        )
    }

    private var emptyStateTitle: String {
        if mode == .migration {
            return L10n.text("尚无可安全搬移的文件", "No Files Ready to Move Safely")
        }
        return rawItems.isEmpty
            ? L10n.text("未发现大型文件", "No Large Files Found")
            : L10n.text("没有符合当前条件的大型文件", "No Large Files Match These Filters")
    }

    private var emptyStateDetail: String {
        if mode == .migration {
            return rawItems.isEmpty
                ? L10n.text("先扫描大型文件，再选择外接硬盘复制并验证；原件处理需要另行确认", "Scan large files first, then choose an external drive to copy and verify them; handling originals needs a separate confirmation")
                : L10n.text("当前扫描结果中没有位于用户目录、可安全搬移的普通文件", "The current scan has no regular user files eligible for safe migration")
        }
        return rawItems.isEmpty
            ? L10n.text("重新扫描后会在这里列出可审查项目", "Rescan to list files worth reviewing")
            : L10n.text("换筛选或重新扫描", "Change filter or rescan")
    }
}

struct LargeFilesScanLandingView: View {
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
                return .completed(L10n.text("已找到 \(count) 个可搬移 App", "Found \(count) movable apps"))
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
        FileToolLandingPage(
            title: route.sidebarTitle,
            subtitle: route.pageSubtitle,
            systemImage: route.systemImage,
            configurationTitle: mode == .migration
                ? L10n.text("搬移来源", "Migration Source")
                : L10n.text("分析范围", "Analysis Scope"),
            actionTitle: scanActionTitle,
            actionDetail: scanActionDetail,
            actionSystemImage: hasResult ? "arrow.clockwise" : "doc.text.magnifyingglass",
            status: status,
            isLoading: isLoading,
            isActionDisabled: !canStart,
            trustText: trustText,
            action: startSelectedScan
        ) {
            VStack(spacing: AppDesignTokens.Spacing.medium) {
                if mode == .analysis {
                    storageTargetPicker
                    analysisCategoryLegend
                } else {
                    migrationConfiguration
                }

                if isLoading {
                    scanProgressView
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
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
        VStack(spacing: AppDesignTokens.Spacing.small) {
            ForEach(workspace.storageMapTargets) { target in
                let isSelected = workspace.selectedStorageMapTargetID == target.id
                Button {
                    workspace.selectedStorageMapTargetID = target.id
                } label: {
                    HStack(spacing: AppDesignTokens.Spacing.medium) {
                        Image(systemName: target.systemImage)
                            .font(.title2)
                            .foregroundStyle(AppDesignTokens.Palette.storage)
                            .frame(width: 30)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
                            Text(target.title)
                                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                            Text(target.path)
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? AppDesignTokens.Palette.storage : AppDesignTokens.Palette.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .padding(8)
                    .contentShape(Rectangle())
                    .appSelectableRowSurface(isSelected: isSelected, isFocused: false)
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityLabel("\(target.title) · \(target.path)")
                .accessibilityHint(L10n.text("选择分析范围后，点击分析磁盘空间开始", "Choose a scope, then select Analyze Disk Space to begin"))
                .help(target.path)
                .disabled(isLoading)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("分析范围", "Analysis Scope"))
    }

    private var analysisCategoryLegend: some View {
        HStack(spacing: 8) {
            category(L10n.text("文档", "Documents"), "doc.fill", .cyan)
            category(L10n.text("媒体", "Media"), "photo.fill", .pink)
            category(L10n.text("归档", "Archives"), "archivebox.fill", .orange)
            category(L10n.text("其他", "Other"), "puzzlepiece.fill", .green)
        }
    }

    private func category(_ title: String, _ symbol: String, _ color: Color) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 24, weight: .regular)).foregroundStyle(color)
            Text(title).font(AppDesignTokens.Typography.metadata)
        }
        .frame(maxWidth: .infinity, minHeight: 63)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.14)))
    }

    private var migrationConfiguration: some View {
        VStack(spacing: AppDesignTokens.Spacing.small) {
            migrationSourceMenu
            migrationDestinationMenu

            Picker(L10n.text("类型", "Type"), selection: $workspace.migrationKind) {
                Label(L10n.text("文件", "Files"), systemImage: "folder")
                    .tag(ExternalMigrationItem.Kind.file)
                Label(L10n.text("应用", "Apps"), systemImage: "app")
                    .tag(ExternalMigrationItem.Kind.application)
            }
            .pickerStyle(.segmented)

            Toggle(isOn: .constant(true)) {
                Label(
                    L10n.text("搬移前生成计划并再次确认", "Create a plan and confirm before moving"),
                    systemImage: "checkmark.shield.fill"
                )
                .font(AppDesignTokens.Typography.compactLabel.weight(.semibold))
                .foregroundStyle(AppDesignTokens.Palette.success)
            }
            .toggleStyle(.switch)
            .disabled(true)
        }
        .frame(maxWidth: .infinity)
    }

    private var migrationSourceMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                Button(L10n.text("用户可访问的文件夹", "User-accessible folders")) {
                    workspace.selectMigrationSource(nil)
                }
                Divider()
                Button(L10n.text("选择文件夹…", "Choose Folder…")) { chooseMigrationSource() }
            } label: {
                Label(L10n.text("来源", "Source"), systemImage: "folder.fill")
            }
            .menuStyle(.borderlessButton)
            Text(workspace.migrationSourcePath ?? L10n.text("用户可访问的文件夹", "User-accessible folders"))
                .font(AppDesignTokens.Typography.compactLabel)
                .lineLimit(2).truncationMode(.middle)
                .help(workspace.migrationSourcePath ?? L10n.text("用户可访问的文件夹", "User-accessible folders"))
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private var migrationDestinationMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                if externalVolumes.isEmpty {
                    Text(L10n.text("未连接可写的物理外接硬盘", "No writable physical external drive"))
                } else {
                    ForEach(externalVolumes) { volume in
                        Button("\(volume.name) · \(ByteFormat.string(volume.availableBytes))") {
                            workspace.migrationDestinationVolumeID = volume.id
                        }
                    }
                }
                Divider()
                Button(L10n.text("刷新外接设备", "Refresh External Drives")) {
                    Task { await refreshExternalVolumes() }
                }
            } label: {
                Label(L10n.text("目标位置", "Destination"), systemImage: "externaldrive.fill")
            }
            .menuStyle(.borderlessButton)
            .disabled(isRefreshingVolumes)
            Text(selectedVolume?.url.path ?? L10n.text("未连接可写的物理外接硬盘", "No writable physical external drive"))
                .font(AppDesignTokens.Typography.compactLabel)
                .lineLimit(2).truncationMode(.middle)
                .help(selectedVolume?.url.path ?? L10n.text("请连接外接硬盘", "Connect an external drive"))
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private var selectedVolume: ExternalStorageVolume? {
        externalVolumes.first { $0.id == workspace.migrationDestinationVolumeID }
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

    private var scanProgressView: some View {
        HStack(alignment: .center, spacing: AppDesignTokens.Spacing.medium) {
            scanProgressDetails
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            cancelScanButton
        }
        .frame(maxWidth: 420)
    }

    private var scanProgressDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if mode == .migration, let progress = workspace.progress {
                ProgressView(value: progress.fractionCompleted)
                    .tint(AppDesignTokens.Palette.storage)
                    .frame(maxWidth: 280)
                Text(L10n.text(
                    "已发现 \(progress.discoveredItemCount) 项 · \(ByteFormat.string(progress.discoveredBytes))",
                    "\(progress.discoveredItemCount) items · \(ByteFormat.string(progress.discoveredBytes)) discovered"
                ))
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let progress = workspace.storageAnalysisProgress {
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text(
                        "已读取 \(progress.inspectedItemCount) 项 · 已测量 \(ByteFormat.storageString(progress.measuredBytes))",
                        "\(progress.inspectedItemCount) items · \(ByteFormat.storageString(progress.measuredBytes)) measured"
                    ))
                        .font(AppDesignTokens.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
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

private struct LargeFileRow: View {
    let item: StorageItem
    @ObservedObject var store: ScanStore
    let migrationItem: ExternalMigrationItem?
    let isMigrating: Bool
    let isMigrationDisabled: Bool
    let completedMigration: ExternalMigrationCompletion?
    let onMigrate: (ExternalMigrationItem) -> Void
    let onHandleOriginal: (ExternalMigrationItem, ExternalMigrationCompletion) -> Void

    private var kind: LargeFileKind {
        LargeFileKind.classify(item)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: kind.systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.title2)
                .foregroundStyle(kind.tint)
                .frame(width: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(AppDesignTokens.Typography.cardTitle)
                        .fixedSize(horizontal: false, vertical: true)

                    if item.status == .movedToTrash {
                        Label(L10n.text("已移到废纸篓", "Moved to Trash"), systemImage: "trash.fill")
                            .font(AppTypography.body)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Text(ByteFormat.string(item.sizeBytes))
                        .font(AppDesignTokens.Typography.metadata.monospacedDigit())
                        .foregroundStyle(kind.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Label(kind.title, systemImage: kind.systemImage)
                            .foregroundStyle(kind.tint)

                        Divider()
                            .frame(height: 12)

                        Label(LargeFilePresenter.sourceTitle(for: item), systemImage: "folder.fill")
                            .foregroundStyle(.secondary)

                        Divider()
                            .frame(height: 12)

                        Label(item.tier.title, systemImage: item.tier.systemImage)
                            .foregroundStyle(item.tier.color)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Label(kind.title, systemImage: kind.systemImage)
                            .foregroundStyle(kind.tint)
                        Label(LargeFilePresenter.sourceTitle(for: item), systemImage: "folder.fill")
                            .foregroundStyle(.secondary)
                        Label(item.tier.title, systemImage: item.tier.systemImage)
                            .foregroundStyle(item.tier.color)
                    }
                }
                .font(AppTypography.body)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(kind.shortDescription)
                            .foregroundStyle(.secondary)
                        Text(item.path)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.shortDescription)
                            .foregroundStyle(.secondary)
                        Text(item.path)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(AppDesignTokens.Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            HStack(spacing: 7) {
                Button {
                    store.reveal(item.openPath.isEmpty ? item.path : item.openPath)
                } label: {
                    Label(L10n.text("在访达中显示", "Show in Finder"), systemImage: "folder")
                }
                .appButtonChrome(.secondary)

                if let completedMigration {
                    Button {
                        ExternalDriveMigrationService.reveal(completedMigration.destinationURL)
                    } label: {
                        Label(
                            completedMigration.didMoveSourceToTrash
                                ? L10n.text("已迁移", "Migrated")
                                : L10n.text("已复制", "Copied"),
                            systemImage: "checkmark.circle"
                        )
                    }
                    .appButtonChrome(.secondary)
                    if !completedMigration.didMoveSourceToTrash, let migrationItem {
                        Button {
                            onHandleOriginal(migrationItem, completedMigration)
                        } label: {
                            Label(L10n.text("处理原件", "Handle Original"), systemImage: "trash")
                        }
                        .appButtonChrome(.secondary)
                        .disabled(isMigrationDisabled)
                    }
                } else if let migrationItem {
                    Button {
                        onMigrate(migrationItem)
                    } label: {
                        if isMigrating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(L10n.text("复制到外接硬盘", "Copy to External Drive"), systemImage: "externaldrive.badge.plus")
                        }
                    }
                    .appButtonChrome(.secondary)
                    .disabled(isMigrationDisabled)
                }

                if item.canMoveToTrash, completedMigration == nil {
                    Button(role: .destructive) {
                        store.requestTrash(item)
                    } label: {
                        Label(L10n.text("移到废纸篓", "Move to Trash"), systemImage: "trash")
                    }
                    .appButtonChrome(.secondary)
                    .disabled(!store.canRequestTrash(item) || isMigrationDisabled)
                }
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: kind.tint, elevated: false, prominence: .quiet)
    }
}

private struct ExternalAppMigrationRow: View {
    let item: ExternalMigrationItem
    let isMigrating: Bool
    let completedMigration: ExternalMigrationCompletion?
    let isDisabled: Bool
    let onMigrate: () -> Void
    let onHandleOriginal: (ExternalMigrationCompletion) -> Void

    var body: some View {
        HStack(spacing: 10) {
            CachedAppIconView(path: item.sourceURL.path, size: 28) {
                Image(systemName: "app.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AppDesignTokens.Palette.information)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(AppDesignTokens.Typography.inlineTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ByteFormat.string(item.sizeBytes))
                    .font(AppDesignTokens.Typography.secondary.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let completedMigration {
                Button(L10n.text("在访达中显示", "Show in Finder")) {
                    ExternalDriveMigrationService.reveal(completedMigration.destinationURL)
                }
                .appButtonChrome(.secondary)
                if !completedMigration.didMoveSourceToTrash {
                    Button(L10n.text("处理原件", "Handle Original")) {
                        onHandleOriginal(completedMigration)
                    }
                    .appButtonChrome(.secondary)
                    .disabled(isDisabled)
                }
            } else {
                Button {
                    onMigrate()
                } label: {
                    if isMigrating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(L10n.text("复制 App 本体", "Copy App Bundle"), systemImage: "externaldrive.badge.plus")
                    }
                }
                .appButtonChrome(.secondary)
                .disabled(isDisabled)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ExternalMigrationNotice: Equatable {
    let message: String
    let isError: Bool
    let destinationURL: URL?
}

private struct ExternalMigrationCompletion: Equatable {
    let destinationURL: URL
    let volume: ExternalStorageVolume
    let didMoveSourceToTrash: Bool
}

private struct PendingOriginalRemoval: Equatable, Sendable {
    let item: ExternalMigrationItem
    let destinationURL: URL
    let volume: ExternalStorageVolume
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

private extension LargeFileKind {
    var tint: Color {
        switch self {
        case .folder: AppDesignTokens.Palette.storage
        case .video: AppDesignTokens.Palette.destructive
        case .installer: AppDesignTokens.Palette.warning
        case .archive: AppDesignTokens.Palette.caution
        case .document: AppDesignTokens.Palette.information
        case .image: AppDesignTokens.Palette.sensitive
        case .audio: AppDesignTokens.Palette.diagnostic
        case .mailAttachment: AppDesignTokens.Palette.tertiary
        case .developer: AppDesignTokens.Palette.secondary
        case .other: .secondary
        }
    }
}

private extension LargeFileFilter {
    var tint: Color {
        switch self {
        case .all: AppDesignTokens.Palette.storage
        case .folder: LargeFileKind.folder.tint
        case .video: LargeFileKind.video.tint
        case .installer: LargeFileKind.installer.tint
        case .archive: LargeFileKind.archive.tint
        case .document: LargeFileKind.document.tint
        case .image: LargeFileKind.image.tint
        case .audio: LargeFileKind.audio.tint
        case .mailAttachment: LargeFileKind.mailAttachment.tint
        case .developer: LargeFileKind.developer.tint
        case .other: LargeFileKind.other.tint
        }
    }
}
