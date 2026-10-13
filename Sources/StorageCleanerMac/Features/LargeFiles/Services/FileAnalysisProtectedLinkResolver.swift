import Darwin
import Foundation

/// D54：只读目录名称和链接元数据，不读取凭据内容，也不递归扫描数据。
///
/// r2-fa-followups P1-1：每个目录只列一次，每个名字只折叠一次，查名字用
/// “折叠名 → 实际名”字典；容器的 `Data` 直接 lstat，不再列目录；不是链接的
/// 项目沿用上层已解析的路径，不再逐项解析。耗时随项目数线性增长。它读文件
/// 系统，调用方放在主线程以外（`LargeFilesStore.resetTrash`）。
enum FileAnalysisProtectedLinkResolver {
    static func locations(homePath: String, appDataPath: String) -> [FileAnalysisProtectedLocation] {
        let manager = FileManager.default
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let policy = FileAnalysisTrashPolicy(rootPath: "/", targetKind: .internalVolume,
                                             homePath: homePath, appDataPath: appDataPath, excludedPaths: [])
        var result: [FileAnalysisProtectedLocation] = []
        // 每个目录：折叠后的名字 → 磁盘上的实际名字（区分大小写的卷上可能有几个）。
        var listings: [String: [String: [String]]] = [:]

        func children(_ parent: URL) -> [String: [String]] {
            if let cached = listings[parent.path] { return cached }
            var names: [String: [String]] = [:]
            for name in (try? manager.contentsOfDirectory(atPath: parent.path)) ?? [] {
                names[FileAnalysisTrashPolicy.protectedName(name), default: []].append(name)
            }
            listings[parent.path] = names
            return names
        }
        /// 每个分量的折叠名只查字典；结果用磁盘上的实际拼写。
        func matchingPaths(_ relative: String) -> [URL] {
            var parents = [home]
            for component in relative.split(separator: "/") {
                let key = FileAnalysisTrashPolicy.protectedName(String(component))
                parents = parents.flatMap { parent in
                    (children(parent)[key] ?? []).sorted().map { parent.appendingPathComponent($0) }
                }
            }
            return parents
        }
        /// Records the item when it, or a folder above it, is a link, and
        /// returns where it really is (nil when it is not there). A non-link
        /// under an already resolved folder is that folder's path plus its
        /// name, so only links and the starting folders are resolved.
        @discardableResult
        func add(_ url: URL, inside resolvedParent: String?) -> String? {
            var status = stat()
            guard Darwin.lstat(url.path, &status) == 0 else { return nil }
            let resolved: String
            if status.st_mode & S_IFMT != S_IFLNK, let resolvedParent {
                resolved = StorageMapAnalysisIndex.childPath(url.lastPathComponent, in: resolvedParent)
            } else {
                resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            }
            guard resolved != url.standardizedFileURL.path else { return resolved }
            // A link's own resource values describe the link, not its target;
            // ask the resolved target whether it is a folder.
            let directory = (try? URL(fileURLWithPath: resolved).resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            guard let block = policy.block(path: url.path, name: url.lastPathComponent, kind: "folder",
                                           isDirectory: directory, isEstimated: false) else { return resolved }
            let whole: Bool
            switch block {
            case .systemData, .credentials, .appData, .cloudStorage: whole = true
            case .standardFolder, .libraryFolder, .appContainer: whole = false
            default: return resolved
            }
            let location = FileAnalysisProtectedLocation(path: resolved, block: block, protectsContents: whole)
            if !result.contains(location) { result.append(location) }
            return resolved
        }

        for relative in FileAnalysisTrashPolicy.standardFolderNames.sorted()
            + FileAnalysisTrashPolicy.credentialPaths + FileAnalysisTrashPolicy.appDataRelativePaths {
            matchingPaths(relative).forEach { add($0, inside: nil) }
        }
        add(URL(fileURLWithPath: appDataPath), inside: nil)
        for library in matchingPaths("Library") {
            guard let resolvedLibrary = add(library, inside: nil) else { continue }
            for (key, names) in children(library).sorted(by: { $0.key < $1.key }) {
                for name in names.sorted() {
                    let folder = library.appendingPathComponent(name)
                    guard let resolvedFolder = add(folder, inside: resolvedLibrary) else { continue }
                    if FileAnalysisTrashPolicy.foldedSharedLibraryFolderNames.contains(key) {
                        let holdsContainers = FileAnalysisTrashPolicy.foldedAppContainerFolderNames.contains(key)
                        for entryName in children(folder).values.joined().sorted() {
                            let entry = folder.appendingPathComponent(entryName)
                            // 不遍历应用数据；容器只直接查 Data 这个已知名称。
                            guard let resolvedEntry = add(entry, inside: resolvedFolder), holdsContainers else { continue }
                            add(entry.appendingPathComponent("Data"), inside: resolvedEntry)
                        }
                    } else if key == "caches" {
                        for (entryKey, entryNames) in children(folder)
                        where entryKey.hasPrefix("storagecleanerintegration-") {
                            entryNames.sorted().forEach { add(folder.appendingPathComponent($0), inside: resolvedFolder) }
                        }
                    }
                }
            }
        }
        return result
    }
}
