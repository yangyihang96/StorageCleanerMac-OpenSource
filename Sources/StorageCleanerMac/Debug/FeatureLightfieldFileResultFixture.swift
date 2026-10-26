#if DEBUG
import SwiftUI

/// Inert completed-index/value fixtures. They share production bodies without
/// a ScanStore, scanner, external-drive provider or file-operation callback.
struct FeatureLightfieldFileResultFixture: View {
    let module: ReviewFilter
    var isSimilarPhotos = false
    @State private var surface: Int
    @State private var spaceMapStyle: SpaceMapViewStyle
    @State private var spaceMapColorMode: SpaceMapColorMode
    private var selectionReclaim: CleanupSelectionReclaimable?
    private var isEstimatingReclaim: Bool
    @State private var destinationID = Self.volume.id
    @State private var selections: Set<String> = []
    @State private var navigation: [StorageMapDirectorySnapshot] = [Self.analysis.rootSnapshot]
    /// D154 batch 3G: the studio shows the Space Lens page.
    @Environment(\.careStudioClassicResults) private var usesClassicPages
    init(module: ReviewFilter, isSimilarPhotos: Bool = false, analysisView: Int? = nil,
         spaceMapStyle: SpaceMapViewStyle = .bubbles, spaceMapColorMode: SpaceMapColorMode = .type,
         selectionReclaim: CleanupSelectionReclaimable? = nil, isEstimatingReclaim: Bool = false) {
        self.module = module
        self.isSimilarPhotos = isSimilarPhotos
        _spaceMapStyle = State(initialValue: spaceMapStyle)
        _spaceMapColorMode = State(initialValue: spaceMapColorMode)
        self.selectionReclaim = selectionReclaim
        self.isEstimatingReclaim = isEstimatingReclaim
        _surface = State(initialValue: analysisView ?? FeaturePresentationDemo.analysisView(arguments: ProcessInfo.processInfo.arguments))
    }
    var body: some View {
        Group {
            if module == .largeFiles && !usesClassicPages {
                CareStudioSpaceLensPage(result: Self.analysis, navigation: navigation,
                    types: FileLightfieldPresentation.types(Self.analysis), largest: FileLightfieldPresentation.largest(Self.analysis.index),
                    fileCount: FileLightfieldPresentation.fileCount(Self.analysis.index), surface: $surface,
                    mapStyle: $spaceMapStyle, mapColorMode: $spaceMapColorMode, checkedPaths: selections,
                    selectionState: { selections.contains($0.id) ? .selected : .available },
                    selectedBytes: StorageTreemapPresentation.visibleEntries(from: navigation.last ?? Self.analysis.rootSnapshot)
                        .filter { selections.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes },
                    selectionReclaim: selectionReclaim, isEstimatingReclaim: isEstimatingReclaim,
                    status: L10n.text("演示索引 · 未执行扫描或移动", "Demo index · No scan or move performed"),
                    canReview: !selections.isEmpty, onReview: {},
                    onToggle: { if selections.contains($0.id) { selections.remove($0.id) } else { selections.insert($0.id) } },
                    onOpen: { entry in openDirectory(entry) }, onBreadcrumb: { index in
                        if navigation.indices.contains(index) { navigation = Array(navigation.prefix(index + 1)) }
                    }, onOpenFromRoot: { entry in
                        navigation = [Self.analysis.rootSnapshot]
                        openDirectory(entry)
                    })
            } else if module == .largeFiles {
                FeatureLightfieldPage(module: .largeFiles, phase: .result, title: ReviewFilter.largeFiles.sidebarTitle,
                    status: L10n.text("演示索引 · 未执行扫描或移动", "Demo index · No scan or move performed"),
                    safety: L10n.text("演示夹具 · 移到废纸篓前确认", "Demo fixture · Confirm before moving to Trash"),
                    actionTitle: L10n.text("移到废纸篓 · 已选 \(ByteFormat.count(selections.count))", "Move to Trash · \(ByteFormat.count(selections.count)) selected"),
                    actionEnabled: !selections.isEmpty, showsArtwork: false, action: {}) {
                    LightfieldFileResults(summary: LightfieldSummary(module: .largeFiles,
                        label: StorageCapacityPresentation.summaryLabel(isComplete: Self.analysis.rootSnapshot.isComplete, path: Self.analysis.rootSnapshot.path), value: "185.4", unit: "GB",
                        secondary: [.init(id: "count", label: L10n.text("已索引文件", "Indexed Files"), value: String(FileLightfieldPresentation.fileCount(Self.analysis.index))),
                            .init(id: "free", label: L10n.text("磁盘可用", "Available Space"), value: "320 GB")]), compactBodyHeight: 640) {
                        FileAnalysisLightfieldBody(result: Self.analysis, navigation: navigation,
                            types: FileLightfieldPresentation.types(Self.analysis), largest: FileLightfieldPresentation.largest(Self.analysis.index),
                            fileCount: FileLightfieldPresentation.fileCount(Self.analysis.index), surface: $surface,
                            selectionState: { selections.contains($0.id) ? .selected : .available },
                            onToggle: { if selections.contains($0.id) { selections.remove($0.id) } else { selections.insert($0.id) } },
                            onOpen: { entry in openDirectory(entry) }, onBreadcrumb: { index in
                                if navigation.indices.contains(index) { navigation = Array(navigation.prefix(index + 1)) }
                            })
                    }
                }
            } else if module == .migration {
                FileMigrationLightfieldView(entries: Self.migrationEntries, volumes: [Self.volume],
                    destinationID: $destinationID, sourceRoot: "/Fixture", completions: [:],
                    now: Self.referenceDate, onRefresh: {}, onRescan: {}, onCancel: {},
                    onCopy: { _ in }, onOriginal: { _, _ in }, onReveal: { _ in })
            } else {
                let groups = Self.duplicateGroups(similar: isSimilarPhotos)
                FeatureLightfieldPage(module: .duplicates, phase: .result,
                    title: isSimilarPhotos ? L10n.text("相似照片", "Similar Photos") : ReviewFilter.duplicates.sidebarTitle,
                    status: L10n.text("演示结果 · 尚未选择", "Demo result · Nothing selected"),
                    safety: isSimilarPhotos ? L10n.text("相似候选需人工确认", "Similar candidates require manual review") : L10n.text("每组至少保留一份", "Keep a copy in each group"),
                    actionTitle: L10n.text("移到废纸篓 · 0 MB", "Move to Trash · 0 MB"), actionEnabled: false,
                    showsArtwork: false, artwork: isSimilarPhotos ? .similarPhotos : nil, action: {}) {
                    LightfieldFileResults(summary: LightfieldSummary(module: .duplicates,
                        label: isSimilarPhotos ? L10n.text("待审阅相似候选", "Similar Candidates to Review") : L10n.text("逻辑重复数据", "Logical Duplicate Data"),
                        value: isSimilarPhotos ? String(groups.count) : "4.5", unit: isSimilarPhotos ? L10n.text("组", "groups") : "GB",
                        secondary: isSimilarPhotos
                            ? [.init(id: "count", label: L10n.text("候选照片", "Candidate Photos"), value: String(groups.flatMap(\.items).count)),
                                .init(id: "bytes", label: L10n.text("候选总量", "Candidate Size"), value: ByteFormat.storageString(FileLightfieldPresentation.sum(groups.flatMap(\.items).map(\.sizeBytes))))]
                            : [.init(id: "count", label: L10n.text("内容确认的组", "Confirmed Groups"), value: String(groups.count)),
                                .init(id: "physical", label: L10n.text("物理可释放", "Physical Savings"), value: L10n.text("待确认", "Unconfirmed"))],
                        artwork: isSimilarPhotos ? .similarPhotos : nil)) {
                        FeatureOptionsScrollView(probePrefix: "lightfield.duplicates.list", balancesContent: false, usesLightfield: true, fadesResults: true) {
                            DuplicateLightfieldBody(groups: groups, isSimilarPhotos: isSimilarPhotos, selectedIDs: [],
                                onSelected: { _, _ in }, onReveal: { _ in }, onCopyPath: { _ in })
                        }
                    }
                }
            }
        }.environment(\.featurePresentationIsFixture, true)
    }
    static let referenceDate = Date(timeIntervalSince1970: 1791504000) // Approved demoToday: 2026-10-09 UTC.
    static let volume = ExternalStorageVolume(url: URL(fileURLWithPath: "/Fixture/Archive"), name: "示例归档盘",
        availableBytes: 640_000_000_000, totalBytes: 1_000_000_000_000, fileSystem: "APFS", supportsApplications: true)
    static func childSnapshot(path: String) -> StorageMapDirectorySnapshot? {
        guard let aggregate = analysis.index.directories[path], let children = analysis.index.childrenByDirectory[path] else { return nil }
        let entries = children.map { child in
            let childPath = (path as NSString).appendingPathComponent(child.name)
            return StorageTreemapEntry(id: childPath, title: child.name, path: childPath, sizeBytes: child.sizeBytes ?? 0,
                kind: child.kind, isDirectory: child.isDirectory, canDescend: child.canDescend, isEstimated: child.isEstimated)
        }
        return .init(path: path, title: (path as NSString).lastPathComponent, entries: entries,
            measuredBytes: aggregate.sizeBytes, inspectedItemCount: children.count, omittedEntryCount: 0, isComplete: true)
    }

    private func openDirectory(_ entry: StorageTreemapEntry) {
        guard entry.canDescend, let base = navigation.last?.path,
              entry.path.hasPrefix(base == "/" ? "/" : base + "/") else { return }
        var paths = [entry.path]
        var parent = DiskScanner.storageMapParentPath(entry.path)
        while parent != base {
            guard parent != "/", parent.hasPrefix(base + "/") else { return }
            paths.append(parent)
            parent = DiskScanner.storageMapParentPath(parent)
        }
        let snapshots = paths.reversed().compactMap { Self.childSnapshot(path: $0) }
        guard snapshots.count == paths.count else { return }
        navigation.append(contentsOf: snapshots)
    }
    static let migrationEntries: [LightfieldMigrationEntry] = {
        // The approved r3 sample totals 17.3 GB; all paths remain fictitious.
        let rows: [(String, String, Int64, Int, Int, Int)] = [
            ("海岸素材-4K.mov", "Movies/视频项目", 6_300_000_000, 2025, 2, 16),
            ("旅行剪辑.mov", "Movies/旅行剪辑/完成导出", 2_200_000_000, 2025, 7, 22),
            ("城市延时.mov", "Downloads/素材交付", 800_000_000, 2026, 4, 20),
            ("项目预览.mp4", "Desktop/交付", 500_000_000, 2026, 7, 11),
            ("设计资源.psd", "Documents/项目文件", 900_000_000, 2026, 9, 4),
            ("海岸全景.tif", "Pictures/旅行素材", 300_000_000, 2025, 10, 24),
            ("开发工具归档.xip", "Downloads/安装包/旧版工具", 1_600_000_000, 2024, 11, 20),
            ("原始素材.zip", "Pictures/原始素材/已归档", 2_100_000_000, 2026, 2, 6),
            ("现场录音.wav", "Music/项目素材", 1_100_000_000, 2025, 3, 17),
            ("配乐混音.wav", "Music/配乐版本", 600_000_000, 2025, 12, 1),
            ("项目演示.key", "Documents/演示", 500_000_000, 2026, 8, 19),
            ("设计手册.pdf", "Desktop/项目归档", 400_000_000, 2024, 7, 8)]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return rows.enumerated().map { index, row in
            let path = "/Fixture/" + (index == 0 ? String(repeating: "Long Project Folder/", count: 4) : "") + row.1 + "/" + row.0
            return LightfieldMigrationEntry(item: .init(id: "migration-\(index)", title: row.0,
                sourceURL: URL(fileURLWithPath: path), sizeBytes: row.2, kind: .file, bundleIdentifier: ""),
                modifiedAt: calendar.date(from: DateComponents(year: row.3, month: row.4, day: row.5)))
        }
    }()
    static func duplicateGroups(similar: Bool) -> [DuplicateDisplayGroup] {
        (0..<(similar ? 3 : 4)).map { group in
            let count = similar ? (group == 0 ? 4 : 3) : (group == 1 ? 3 : 2)
            let sizes: [Int64] = similar ? [8_700_000, 8_700_000, 8_700_000] : [2_200_000_000, 800_000_000, 400_000_000, 300_000_000]
            let title = similar ? "相似候选 \(group + 1)" : ["旅行剪辑.mov", "项目设计.psd", "归档包.zip", "录音.m4a"][group]
            let items = (0..<count).map { index in
                StorageItem(id: "group-\(group)-\(index)", title: similar ? "照片-\(index + 1).heic" : title,
                    path: "/Fixture/副本-\(index)/" + title, groupTitle: title, sizeBytes: sizes[group], tier: .yellow,
                    kind: similar ? "heic" : "file", reason: "演示", recommendation: "人工审阅", risk: "演示", requiresClose: "",
                    trashPaths: [], openPath: "", isDirectory: false, duplicateGroupID: "group-\(group)",
                    duplicateMatchKind: similar ? DuplicateFileCandidateGroup.Rule.similarImage.rawValue : DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue, status: .available)
            }
            return DuplicateDisplayGroup(id: "group-\(group)", title: title, sizeBytes: sizes[group], items: items,
                isContentConfirmed: !similar, candidateRule: similar ? .similarImage : nil, relationship: .unknown, physicalReclaimableBytes: nil)
        }
    }
    static let analysis: StorageMapAnalysisResult = {
        let root = "/Fixture/Home"
        let target = StorageMapScanTarget(path: root, title: "~", kind: .homeDirectory)
        // D70: the frozen r4 tree, sizes and profiles; only paths are fictitious.
        // Indexed kind tags represent the mockup categories, not filesystem reads.
        func profile(_ values: [(StorageMapContentCategory, Int64)]) -> StorageMapContentProfile {
            var result = StorageMapContentProfile()
            for (category, bytes) in values { result.merge(.init(category: category, bytes: bytes)) }
            return result
        }
        let directories: [String: StorageMapDirectoryAggregate] = [
            root: .init(sizeBytes: 185_400_000_000, immediateChildCount: 8, descendantItemCount: 38, contentProfile: profile([(.video, 68_700_000_000), (.document, 7_100_000_000), (.audio, 6_100_000_000), (.archive, 49_000_000_000), (.image, 12_300_000_000), (.developer, 19_600_000_000), (.system, 7_400_000_000), (.application, 14_600_000_000), (.data, 600_000_000)])),
            root + "/影片素材": .init(sizeBytes: 72_400_000_000, immediateChildCount: 5, descendantItemCount: 9, contentProfile: profile([(.video, 68_700_000_000), (.document, 1_000_000_000), (.audio, 2_700_000_000)])),
            root + "/影片素材/原始拍摄": .init(sizeBytes: 48_600_000_000, immediateChildCount: 4, descendantItemCount: 4, contentProfile: profile([(.video, 48_100_000_000), (.document, 500_000_000)])),
            root + "/图片归档": .init(sizeBytes: 38_600_000_000, immediateChildCount: 4, descendantItemCount: 4, contentProfile: profile([(.archive, 27_200_000_000), (.image, 11_100_000_000), (.document, 300_000_000)])),
            root + "/代码工程": .init(sizeBytes: 28_200_000_000, immediateChildCount: 3, descendantItemCount: 6, contentProfile: profile([(.developer, 19_600_000_000), (.system, 7_400_000_000), (.image, 1_200_000_000)])),
            root + "/代码工程/构建产物": .init(sizeBytes: 18_600_000_000, immediateChildCount: 2, descendantItemCount: 2, contentProfile: profile([(.developer, 11_200_000_000), (.system, 7_400_000_000)])),
            root + "/代码工程/代码仓库": .init(sizeBytes: 8_400_000_000, immediateChildCount: 1, descendantItemCount: 1, contentProfile: profile([(.developer, 8_400_000_000)])),
            root + "/归档备份": .init(sizeBytes: 21_800_000_000, immediateChildCount: 2, descendantItemCount: 2, contentProfile: profile([(.archive, 21_800_000_000)])),
            root + "/安装包": .init(sizeBytes: 14_600_000_000, immediateChildCount: 2, descendantItemCount: 2, contentProfile: profile([(.application, 14_600_000_000)])),
            root + "/项目文档": .init(sizeBytes: 5_600_000_000, immediateChildCount: 3, descendantItemCount: 3, contentProfile: profile([(.document, 5_600_000_000)])),
            root + "/音乐素材": .init(sizeBytes: 3_400_000_000, immediateChildCount: 2, descendantItemCount: 2, contentProfile: profile([(.audio, 3_400_000_000)])),
            root + "/数据": .init(sizeBytes: 800_000_000, immediateChildCount: 2, descendantItemCount: 2, contentProfile: profile([(.data, 600_000_000), (.document, 200_000_000)])),
        ]
        let children: [String: [StorageMapIndexedEntry]] = [
            root: [
                .init(name: "影片素材", kind: "folder", sizeBytes: 72_400_000_000, isDirectory: true, canDescend: true, isEstimated: false),
                .init(name: "图片归档", kind: "folder", sizeBytes: 38_600_000_000, isDirectory: true, canDescend: true, isEstimated: false),
                .init(name: "代码工程", kind: "folder", sizeBytes: 28_200_000_000, isDirectory: true, canDescend: true, isEstimated: false),
                .init(name: "归档备份", kind: "folder", sizeBytes: 21_800_000_000, isDirectory: true, canDescend: true, isEstimated: false),
                .init(name: "安装包", kind: "folder", sizeBytes: 14_600_000_000, isDirectory: true, canDescend: true, isEstimated: false),
                .init(name: "项目文档", kind: "folder", sizeBytes: 5_600_000_000, isDirectory: true, canDescend: true, isEstimated: false),
                .init(name: "音乐素材", kind: "folder", sizeBytes: 3_400_000_000, isDirectory: true, canDescend: true, isEstimated: false),
                .init(name: "数据", kind: "folder", sizeBytes: 800_000_000, isDirectory: true, canDescend: true, isEstimated: false),
            ],
            root + "/影片素材": [
                .init(name: "原始拍摄", kind: "folder", sizeBytes: 48_600_000_000, isDirectory: true, canDescend: true, isEstimated: false),
                .init(name: "旅行剪辑-4K.mov", kind: "mov", sizeBytes: 15_800_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "成片导出.mov", kind: "mov", sizeBytes: 4_800_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "现场收音.wav", kind: "wav", sizeBytes: 2_700_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "剪辑工程.fcpxml", kind: "pdf", sizeBytes: 500_000_000, isDirectory: false, canDescend: false, isEstimated: false),
            ],
            root + "/影片素材/原始拍摄": [
                .init(name: "海岸长镜头.mov", kind: "mov", sizeBytes: 32_400_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "森林航拍.mov", kind: "mov", sizeBytes: 12_800_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "日落片段.mov", kind: "mov", sizeBytes: 2_900_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "拍摄记录.pdf", kind: "pdf", sizeBytes: 500_000_000, isDirectory: false, canDescend: false, isEstimated: false),
            ],
            root + "/图片归档": [
                .init(name: "相机原片.zip", kind: "zip", sizeBytes: 27_200_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "旅行相册.psd", kind: "heic", sizeBytes: 8_400_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "海岸全景.tif", kind: "heic", sizeBytes: 2_700_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "缩略图联系表.pdf", kind: "pdf", sizeBytes: 300_000_000, isDirectory: false, canDescend: false, isEstimated: false),
            ],
            root + "/代码工程": [
                .init(name: "构建产物", kind: "folder", sizeBytes: 18_600_000_000, isDirectory: true, canDescend: true, isEstimated: false),
                .init(name: "代码仓库", kind: "folder", sizeBytes: 8_400_000_000, isDirectory: true, canDescend: true, isEstimated: false),
                .init(name: "界面素材.psd", kind: "heic", sizeBytes: 1_200_000_000, isDirectory: false, canDescend: false, isEstimated: false),
            ],
            root + "/代码工程/构建产物": [
                .init(name: "构建缓存.a", kind: "swift", sizeBytes: 11_200_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "模拟器镜像.dmg", kind: "plist", sizeBytes: 7_400_000_000, isDirectory: false, canDescend: false, isEstimated: false),
            ],
            root + "/代码工程/代码仓库": [
                .init(name: "仓库对象.pack", kind: "swift", sizeBytes: 8_400_000_000, isDirectory: false, canDescend: false, isEstimated: false),
            ],
            root + "/归档备份": [
                .init(name: "项目备份.zip", kind: "zip", sizeBytes: 16_200_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "旧版资料.zip", kind: "zip", sizeBytes: 5_600_000_000, isDirectory: false, canDescend: false, isEstimated: false),
            ],
            root + "/安装包": [
                .init(name: "开发工具.xip", kind: "pkg", sizeBytes: 9_800_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "媒体工具.dmg", kind: "pkg", sizeBytes: 4_800_000_000, isDirectory: false, canDescend: false, isEstimated: false),
            ],
            root + "/项目文档": [
                .init(name: "项目演示.key", kind: "pdf", sizeBytes: 3_400_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "设计手册.pdf", kind: "pdf", sizeBytes: 1_800_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "研究笔记.pages", kind: "pdf", sizeBytes: 400_000_000, isDirectory: false, canDescend: false, isEstimated: false),
            ],
            root + "/音乐素材": [
                .init(name: "配乐混音.wav", kind: "wav", sizeBytes: 2_400_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "环境录音.wav", kind: "wav", sizeBytes: 1_000_000_000, isDirectory: false, canDescend: false, isEstimated: false),
            ],
            root + "/数据": [
                .init(name: "数据快照.csv", kind: "csv", sizeBytes: 600_000_000, isDirectory: false, canDescend: false, isEstimated: false),
                .init(name: "索引说明.json", kind: "pdf", sizeBytes: 200_000_000, isDirectory: false, canDescend: false, isEstimated: false),
            ],
        ]
        let entries: [StorageTreemapEntry] = [
            .init(id: root + "/影片素材", title: "影片素材", path: root + "/影片素材", sizeBytes: 72_400_000_000, kind: "folder", isDirectory: true, childCount: 5, contentCategory: .video),
            .init(id: root + "/图片归档", title: "图片归档", path: root + "/图片归档", sizeBytes: 38_600_000_000, kind: "folder", isDirectory: true, childCount: 4, contentCategory: .image),
            .init(id: root + "/代码工程", title: "代码工程", path: root + "/代码工程", sizeBytes: 28_200_000_000, kind: "folder", isDirectory: true, childCount: 3, contentCategory: .developer),
            .init(id: root + "/归档备份", title: "归档备份", path: root + "/归档备份", sizeBytes: 21_800_000_000, kind: "folder", isDirectory: true, childCount: 2, contentCategory: .archive),
            .init(id: root + "/安装包", title: "安装包", path: root + "/安装包", sizeBytes: 14_600_000_000, kind: "folder", isDirectory: true, childCount: 2, contentCategory: .application),
            .init(id: root + "/项目文档", title: "项目文档", path: root + "/项目文档", sizeBytes: 5_600_000_000, kind: "folder", isDirectory: true, childCount: 3, contentCategory: .document),
            .init(id: root + "/音乐素材", title: "音乐素材", path: root + "/音乐素材", sizeBytes: 3_400_000_000, kind: "folder", isDirectory: true, childCount: 2, contentCategory: .audio),
            .init(id: root + "/数据", title: "数据", path: root + "/数据", sizeBytes: 800_000_000, kind: "folder", isDirectory: true, childCount: 2, contentCategory: .data),
        ]
        let index = StorageMapAnalysisIndex(rootPath: root, rootVolumeIdentifier: nil, directories: directories,
            childrenByDirectory: children, blockedDirectoryPaths: [], duplicateFilePaths: [])
        let snapshot = StorageMapDirectorySnapshot(path: root, title: "~", entries: entries,
            measuredBytes: 185_400_000_000, inspectedItemCount: 38, omittedEntryCount: 0, isComplete: true)
        return .init(target: target, volumeTotalBytes: 1_000_000_000_000, volumeAvailableBytes: 320_000_000_000,
            inspectedItemCount: 38, omittedItemCount: 0, scanSeconds: 12, index: index, rootSnapshot: snapshot)
    }()
}
#endif
