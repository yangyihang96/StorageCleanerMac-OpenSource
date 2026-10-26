import Foundation

/// D85：独立大文件清单的门槛。只有三档，默认是中间一档。
/// D178：单位跟访达和 CleanMyMac 一样按十进制（1 MB = 1,000,000 字节），
/// 门槛写整数（原来按二进制：50 MiB、200 MiB、1 GiB）。档位名（rawValue）
/// 存在偏好里，所以沿用原来的 `mib50` 这些名字。
enum LargeFileThreshold: String, CaseIterable, Identifiable, Sendable {
    case mib50
    case mib200
    case gib1

    static let standard: LargeFileThreshold = .mib200

    var id: String { rawValue }

    var bytes: Int64 {
        switch self {
        case .mib50: 50_000_000
        case .mib200: 200_000_000
        case .gib1: 1_000_000_000
        }
    }

    /// 单位标注清楚的档位名；不随语言改变单位写法。
    var title: String {
        switch self {
        case .mib50: "50 MB"
        case .mib200: "200 MB"
        case .gib1: "1 GB"
        }
    }

    var detail: String {
        switch self {
        case .mib50:
            L10n.text("门槛较低：结果更多，扫描更久", "Lower threshold: more results, longer scan")
        case .mib200:
            L10n.text("默认门槛", "Default threshold")
        case .gib1:
            L10n.text("只找特别大的项目", "Only very large items")
        }
    }

    static var unitHelp: String {
        L10n.text(
            "按本地占用（分配大小）比较；1 MB = 1,000,000 字节，1 GB = 1000 MB。",
            "Compared by local usage (allocated size); 1 MB = 1,000,000 bytes, 1 GB = 1000 MB."
        )
    }

    /// 偏好里存的值无法识别时回到默认档。
    static func stored(_ rawValue: String?) -> LargeFileThreshold {
        rawValue.flatMap(LargeFileThreshold.init(rawValue:)) ?? .standard
    }
}

/// D84/D85：一次大文件清单扫描的范围与截断情况。大小均为本地占用
/// （分配大小）；测量超时的文件夹只记到本轮量到的下限。
struct LargeFileListingSummary: Equatable, Sendable {
    var ignoredItemCount: Int = 0
    let threshold: LargeFileThreshold
    let resultLimit: Int
    /// 达到门槛并测到的项目数（截断前）。
    let qualifyingCount: Int
    /// 实际显示的项目数（截断后）。
    let shownCount: Int
    /// 扫描用完时间上限，后面的位置没有读完。
    let reachedTimeLimit: Bool
    /// 某个位置的子项目超过单个文件夹的测量上限，或单个位置的结果上限，
    /// 只测了一部分。
    let reachedFolderLimit: Bool
    /// 测量超时、只量到下限的项目路径（已规范化）。
    let lowerBoundPaths: Set<String>

    var reachedResultLimit: Bool { qualifyingCount > shownCount }

    var isTruncated: Bool { reachedResultLimit || reachedTimeLimit || reachedFolderLimit }

    /// 结果页的一行说明；没有截断时也写明门槛与口径。
    var note: String {
        var parts = [L10n.text(
            "门槛 ≥ \(threshold.title) · 按本地占用（分配大小）",
            "Threshold ≥ \(threshold.title) · By local usage (allocated size)"
        )]
        if reachedResultLimit {
            parts.append(L10n.text(
                "仅显示前 \(ByteFormat.count(shownCount)) 项（共找到 \(ByteFormat.count(qualifyingCount)) 项）",
                "Showing only the first \(L10n.items(shownCount)) (\(ByteFormat.count(qualifyingCount)) found)"
            ))
        } else if reachedTimeLimit || reachedFolderLimit {
            // 没到结果上限：已找到的都显示了，只是还有位置没测完，可能漏掉更多。
            parts.append(L10n.text(
                "已显示找到的 \(ByteFormat.count(shownCount)) 项，可能还有未测到的",
                "Showing the \(L10n.items(shownCount)) found; more may not have been measured"
            ))
        }
        if reachedTimeLimit {
            parts.append(L10n.text("已到扫描时间上限，结果不完整", "Scan time limit reached; results are incomplete"))
        } else if reachedFolderLimit {
            parts.append(L10n.text("部分文件夹只测了前一部分项目", "Some folders were only partly measured"))
        }
        if !lowerBoundPaths.isEmpty {
            parts.append(L10n.text(
                "\(ByteFormat.count(lowerBoundPaths.count)) 项测量超时，大小为本轮量到的下限",
                "\(L10n.items(lowerBoundPaths.count)) timed out; sizes are lower bounds"
            ))
        }
        if ignoredItemCount > 0 { parts.append(IgnoreListSnapshot.summary(ignoredItemCount)) }
        return parts.joined(separator: " · ")
    }

    /// 排序、按上限截断，并记下截断情况。排序：大小降序，同样大小按路径。
    static func make(
        candidates: [DirectoryEntry],
        threshold: LargeFileThreshold,
        resultLimit: Int,
        reachedTimeLimit: Bool,
        reachedFolderLimit: Bool,
        lowerBoundPaths: Set<String>,
        ignoredItemCount: Int = 0
    ) -> (entries: [DirectoryEntry], summary: LargeFileListingSummary) {
        // 与改前相同：所有候选（含权限不足的 0 字节占位）按大小降序后取前
        // resultLimit 项；同样大小再按路径，使顺序稳定。
        let limit = max(0, resultLimit)
        let shown = Array(candidates.sorted {
            $0.sizeBytes == $1.sizeBytes ? $0.path < $1.path : $0.sizeBytes > $1.sizeBytes
        }.prefix(limit))
        let measuredShown = shown.filter { !$0.denied }
        let shownPaths = Set(measuredShown.map { PathSafety.normalizedPath($0.path) })
        return (
            shown,
            LargeFileListingSummary(
                ignoredItemCount: ignoredItemCount,
                threshold: threshold,
                resultLimit: limit,
                qualifyingCount: candidates.filter { !$0.denied }.count,
                shownCount: measuredShown.count,
                reachedTimeLimit: reachedTimeLimit,
                reachedFolderLimit: reachedFolderLimit,
                lowerBoundPaths: lowerBoundPaths.intersection(shownPaths)
            )
        )
    }

    /// 时间已用完，大文件这一步根本没开始。
    static func notStarted(threshold: LargeFileThreshold, resultLimit: Int) -> LargeFileListingSummary {
        LargeFileListingSummary(
            threshold: threshold,
            resultLimit: resultLimit,
            qualifyingCount: 0,
            shownCount: 0,
            reachedTimeLimit: true,
            reachedFolderLimit: false,
            lowerBoundPaths: []
        )
    }
}
