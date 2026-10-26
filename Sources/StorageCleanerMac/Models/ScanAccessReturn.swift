import Foundation

/// D100 G5: when the app becomes active again (for example after access was
/// granted in System Settings), the roots the current scan could not read are
/// read again, read-only. Roots that became readable are offered for a rescan
/// once per run; nothing scans until the user asks, and then (D104) only the
/// rules of those roots run, as part of the same results.
struct ScanAccessReturnTracker: Equatable, Sendable {
    /// Roots already offered in this run. Turning access off and on again
    /// does not offer them a second time.
    private(set) var offeredPaths: Set<String> = []

    /// The denied roots of a scan that are worth reading again.
    func pathsToCheck(in permissions: [CleanupPermissionReport]) -> [String] {
        var seen = Set<String>()
        return permissions
            .filter { $0.status == .permissionDenied }
            .map(\.path)
            .filter { !offeredPaths.contains($0) && seen.insert($0).inserted }
    }

    /// The checked roots that are readable now and were not offered before;
    /// they count as offered from here on.
    mutating func recordReadable(_ readable: Set<String>, among checked: [String]) -> [String] {
        let newlyReadable = checked.filter { readable.contains($0) && !offeredPaths.contains($0) }
        offeredPaths.formUnion(newlyReadable)
        return newlyReadable
    }
}

struct ScanAccessReturnNotice: Equatable, Sendable {
    let sessionID: ScanSessionID
    let paths: [String]
    /// What the user knows these roots by: the titles of the rules that
    /// could not read them, without repeats.
    let titles: [String]

    init(session: ScanSession, readablePaths: [String], ruleTitles: [String: String]) {
        sessionID = session.id
        paths = readablePaths
        var seen = Set<String>()
        titles = session.permissions
            .filter { $0.status == .permissionDenied && readablePaths.contains($0.path) }
            .map { ruleTitles[$0.ruleID] ?? ($0.path as NSString).abbreviatingWithTildeInPath }
            .filter { seen.insert($0).inserted }
    }

    var text: String {
        L10n.text(
            "现在可以读取：\(titles.joined(separator: "、"))。本次结果没有包含这些位置；扫描这些位置后会加入本次结果，其他结果不重新扫描。",
            "Now readable: \(titles.joined(separator: ", ")). These results do not include them; scanning them adds them to these results without scanning the rest again."
        )
    }
}
