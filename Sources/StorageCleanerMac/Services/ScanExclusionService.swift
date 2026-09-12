import Foundation

enum ScanExclusionService {
    static let defaultsKey = "scan.excludedPaths.v1"

    static func excludedPaths(defaults: UserDefaults = .standard) -> [String] {
        let rawPaths = defaults.stringArray(forKey: defaultsKey) ?? []
        return normalizedUniquePaths(rawPaths)
    }

    @discardableResult
    static func add(_ path: String, defaults: UserDefaults = .standard) -> Bool {
        let normalized = normalizedPath(path)
        guard isAllowedExclusion(normalized) else { return false }

        let existing = excludedPaths(defaults: defaults)
        guard !existing.contains(normalized) else { return false }

        setExcludedPaths(existing + [normalized], defaults: defaults)
        return true
    }

    static func remove(_ path: String, defaults: UserDefaults = .standard) {
        let normalized = normalizedPath(path)
        let remaining = excludedPaths(defaults: defaults).filter { $0 != normalized }
        setExcludedPaths(remaining, defaults: defaults)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    static func setExcludedPaths(_ paths: [String], defaults: UserDefaults = .standard) {
        let normalized = normalizedUniquePaths(paths).filter(isAllowedExclusion)
        defaults.set(normalized, forKey: defaultsKey)
    }

    static func isExcluded(_ path: String, excludedPaths: [String]) -> Bool {
        let normalized = normalizedPath(path)
        return normalizedUniquePaths(excludedPaths).contains { excluded in
            normalized == excluded || normalized.hasPrefix(excluded + "/")
        }
    }

    /// Returns true when the candidate is excluded or contains an excluded
    /// descendant. This protects aggregate cleanup candidates such as a cache
    /// root when only one child was added to the exclusion list.
    static func intersectsExcludedTree(_ path: String, excludedPaths: [String]) -> Bool {
        let normalized = normalizedPath(path)
        let descendantPrefix = normalized == "/" ? "/" : normalized + "/"
        return normalizedUniquePaths(excludedPaths).contains { excluded in
            normalized == excluded
                || normalized.hasPrefix(excluded + "/")
                || excluded.hasPrefix(descendantPrefix)
        }
    }

    static func canExclude(_ path: String) -> Bool {
        isAllowedExclusion(normalizedPath(path))
    }

    static func displayName(for path: String) -> String {
        let url = URL(fileURLWithPath: normalizedPath(path))
        let name = url.lastPathComponent
        return name.isEmpty ? path : name
    }

    static func markdown(for paths: [String], generatedAt: Date = Date()) -> String {
        let normalizedPaths = normalizedUniquePaths(paths).filter(isAllowedExclusion)

        var lines = [String]()
        lines.append("# \(L10n.text("扫描排除清单", "Scan Exclusion List"))")
        lines.append("")
        lines.append("- \(L10n.text("生成时间", "Generated")): \(displayDate(generatedAt))")
        lines.append("- \(L10n.text("项目数量", "Items")): \(normalizedPaths.count)")
        lines.append("- \(L10n.text("适用范围", "Applies to")): \(L10n.text("智能扫描与重复文件", "Smart scan and duplicate files"))")
        lines.append("- \(L10n.text("安全边界", "Safety boundary")): \(L10n.text("排除项不会被清理；包含排除项的父目录也不会作为整体移到废纸篓。", "Excluded items are not cleaned, and a parent containing an exclusion is never moved to Trash as a whole."))")
        lines.append("")

        if normalizedPaths.isEmpty {
            lines.append(L10n.text("当前没有扫描排除项。", "There are no scan exclusions."))
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("| \(L10n.text("名称", "Name")) | \(L10n.text("类型", "Type")) | \(L10n.text("路径", "Path")) |")
        lines.append("| --- | --- | --- |")
        for path in normalizedPaths {
            lines.append("| \(tableText(displayName(for: path))) | \(tableText(markdownType(for: path))) | `\(path)` |")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func normalizedPath(_ path: String) -> String {
        PathSafety.normalizedPath(path)
    }

    private static func normalizedUniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result = [String]()

        for path in paths {
            let normalized = normalizedPath(path)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }

        return result.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func isAllowedExclusion(_ path: String) -> Bool {
        path != "/" && (PathSafety.isInsideHome(path) || PathSafety.isInsideApplications(path))
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func markdownType(for path: String) -> String {
        path.hasSuffix(".app")
            ? L10n.text("应用", "App")
            : L10n.text("目录或文件", "Folder or file")
    }

    private static func tableText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmed
    }
}
