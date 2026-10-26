import Foundation

/// D84：容量口径说明。D193（用户 10-23 选“改成实际占用”）起空间分析
/// 一律按本地占用（分配大小），/Applications 的应用包也一样，不再有
/// “逻辑大小”和“应用包按逻辑大小的混合”两种口径。大文件清单一律按
/// 本地占用。
enum StorageCapacityBasis: String, CaseIterable, Sendable {
    /// 本地占用（分配大小）：文件在这块磁盘上实际占用的块。
    case allocated
    /// 本轮量到的下限：扫描不完整、超时或权限不足，真实值可能更大。
    case measuredLowerBound
    /// 云端占位：文件只在云端，没有下载，不占本地空间。
    case cloudPlaceholder

    var title: String {
        switch self {
        case .allocated: L10n.text("本地占用（分配大小）", "Local Usage (Allocated Size)")
        case .measuredLowerBound: L10n.text("本轮量到的下限", "Lower Bound Measured This Run")
        case .cloudPlaceholder: L10n.text("云端占位（未下载，不占本地）", "Cloud Placeholder (Not Downloaded, No Local Usage)")
        }
    }

    var explanation: String {
        switch self {
        case .allocated:
            L10n.text(
                "文件在这块磁盘上实际占用的空间。稀疏文件只计已写入的块，因此可能小于逻辑大小。",
                "The space the file actually takes on this disk. Sparse files count only written blocks, so this can be smaller than the logical size."
            )
        case .measuredLowerBound:
            L10n.text(
                "扫描不完整（超时、权限不足、读取失败或被排除）时，只显示本轮实际量到的部分，真实占用可能更大。",
                "When a scan is incomplete (timed out, no permission, unreadable or excluded), only what this run measured is shown; the real usage can be larger."
            )
        case .cloudPlaceholder:
            L10n.text(
                "只在云端、没有下载到本机的文件不占本地空间；测量时不会触发下载。",
                "Files only in the cloud and not downloaded take no local space; measuring never downloads them."
            )
        }
    }
}

enum StorageCapacityPresentation {
    /// 一行的口径：云端占位优先，其次不完整（下限），其余按测量口径。
    ///
    /// 未读入的文件夹（未下载的云端文件夹与被排除、读不出的文件夹在索引里
    /// 看起来一样）一律说成本轮量到的下限，不猜测是云端占位。
    static func basis(for entry: StorageTreemapEntry) -> StorageCapacityBasis {
        if entry.isEstimated && entry.isDirectory { return .measuredLowerBound }
        if entry.isCloudOnly { return .cloudPlaceholder }
        if entry.isEstimated { return .measuredLowerBound }
        return basis(forMeasuredPath: entry.path, isDirectory: entry.isDirectory)
    }

    /// 测量口径：D193 起一律按本地占用，应用包与包含它的文件夹也一样
    /// （D84 时应用包按逻辑大小、上层文件夹为混合口径）。与
    /// `DiskScanner.storageMapPreferredSize` 同源。
    static func basis(forMeasuredPath path: String, isDirectory: Bool) -> StorageCapacityBasis {
        DiskScanner.storageMapSizeBasis(path: path)
    }

    /// 一个目录汇总的口径：不完整时为本轮量到的下限，否则按本地占用。
    static func summaryBasis(isComplete: Bool, path: String) -> StorageCapacityBasis {
        isComplete ? basis(forMeasuredPath: path, isDirectory: true) : .measuredLowerBound
    }

    /// 结果页摘要的短标签。
    static func summaryLabel(isComplete: Bool, path: String) -> String {
        switch summaryBasis(isComplete: isComplete, path: path) {
        case .measuredLowerBound: L10n.text("本轮量到的下限", "Lower Bound This Run")
        case .allocated, .cloudPlaceholder: L10n.text("已分析 · 本地占用", "Analyzed · Local Usage")
        }
    }

    /// 面包屑右侧说明。
    static func snapshotNote(isComplete: Bool, path: String) -> String {
        switch summaryBasis(isComplete: isComplete, path: path) {
        case .measuredLowerBound: L10n.text("部分索引 · 本轮量到的下限", "Partial index · Lower bound this run")
        case .allocated, .cloudPlaceholder: L10n.text("按本地占用（分配大小）", "By local usage (allocated size)")
        }
    }

    /// 行悬停帮助：路径与口径。
    static func rowHelp(_ entry: StorageTreemapEntry) -> String {
        entry.path + "\n" + L10n.text("口径：", "Basis: ") + basis(for: entry).title
    }

    static var hardLinkNote: String {
        L10n.text(
            "硬链接：空间分析把同一文件的多个硬链接只计一次；大文件清单逐项测量，同一份数据出现在两行时两行都会显示它的大小。",
            "Hard links: Space analysis counts several hard links to one file once. The large-file list measures each row on its own, so data shared by two rows shows on both."
        )
    }

    static var cloneNote: String {
        L10n.text(
            "APFS 克隆：克隆文件与原件共享数据块，但系统按各自的完整分配大小报告，因此合计可能大于实际占用；删除其中一份通常释放不了多少空间。",
            "APFS clones: A clone shares blocks with its original, but each reports its full allocated size, so totals can exceed real usage; removing one copy usually frees little."
        )
    }

    static var sparseNote: String {
        L10n.text(
            "稀疏文件：本地占用只计已写入的块，可能远小于逻辑大小（例如虚拟机磁盘）；大文件门槛按本地占用比较。",
            "Sparse files: Local usage counts only written blocks and can be far below the logical size (for example VM disks); the large-file threshold compares local usage."
        )
    }

    static var trashNote: String {
        L10n.text(
            "移入废纸篓不等于释放磁盘空间：项目仍占本地空间，可在“操作记录”中恢复；清空废纸篓后才会释放。",
            "Moving to the Trash does not free disk space: the items still take local space and can be restored from Operation History; space is freed when the Trash is emptied."
        )
    }

    /// D84：移到废纸篓后的完成摘要。容量描述为“已移到废纸篓”，并写明尚未释放。
    static func movedToTrashSummary(count: Int, bytes: Int64) -> String {
        L10n.text(
            "已移到废纸篓 \(ByteFormat.count(count)) 项 · \(ByteFormat.storageString(bytes))（清空废纸篓后才释放）",
            "Moved \(L10n.items(count)) to the Trash · \(ByteFormat.storageString(bytes)) (freed when the Trash is emptied)"
        )
    }

    /// 口径说明页的所有段落，顺序固定。
    static var notes: [(title: String, body: String)] {
        StorageCapacityBasis.allCases.map { ($0.title, $0.explanation) } + [
            (L10n.text("硬链接", "Hard Links"), hardLinkNote),
            (L10n.text("APFS 克隆", "APFS Clones"), cloneNote),
            (L10n.text("稀疏文件", "Sparse Files"), sparseNote),
            (L10n.text("废纸篓", "Trash"), trashNote),
        ]
    }
}
