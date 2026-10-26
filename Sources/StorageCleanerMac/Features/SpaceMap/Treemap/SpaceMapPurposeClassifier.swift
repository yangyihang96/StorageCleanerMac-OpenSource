import Foundation

// Adapted from disktree/core/classify.rs (MIT, © 2026 Tobi Lütke).
// The permission and warranty notice is in SpaceMapTreemapLayout.swift.
enum SpaceMapPurpose: String, CaseIterable, Sendable {
    case code, agentWorkspace, toolchain, synced, git, media, documents, cache, other

    var title: String {
        switch self {
        case .code: L10n.text("代码", "Code")
        case .agentWorkspace: L10n.text("AI 工作区", "AI Workspaces")
        case .toolchain: L10n.text("工具链", "Toolchains")
        case .synced: L10n.text("同步盘", "Synced")
        case .git: L10n.text("版本库", "Git")
        case .media: L10n.text("媒体", "Media")
        case .documents: L10n.text("文档", "Documents")
        case .cache: L10n.text("缓存", "Caches")
        case .other: L10n.text("其他", "Other")
        }
    }

    static let legend: [Self] = [.code, .agentWorkspace, .toolchain, .synced, .git, .media, .documents, .cache]
}

enum SpaceMapReclaimReason: String, CaseIterable, Sendable {
    case regenerableCache, syncHistory, packageStore, buildOutput, reinstallableDependencies
    case sandboxLayers, snapshots, trash, temporary, logs

    var title: String {
        switch self {
        case .regenerableCache: L10n.text("可再生缓存", "Regenerable Caches")
        case .syncHistory: L10n.text("同步历史版本", "Sync History")
        case .packageStore: L10n.text("包管理器仓库", "Package Stores")
        case .buildOutput: L10n.text("构建产物", "Build Output")
        case .reinstallableDependencies: L10n.text("可重装依赖", "Reinstallable Dependencies")
        case .sandboxLayers: L10n.text("沙箱镜像层", "Sandbox Layers")
        case .snapshots: L10n.text("快照", "Snapshots")
        case .trash: L10n.text("废纸篓", "Trash")
        case .temporary: L10n.text("临时文件", "Temporary Files")
        case .logs: L10n.text("日志", "Logs")
        }
    }
}

/// Only rule hits are stored. Files and unrecognized directories inherit the
/// nearest explicit result, including an explicit nil reclaim reason at a
/// protected archive/backup boundary.
struct SpaceMapPurposeMap: Sendable {
    fileprivate struct Classification: Sendable {
        let purpose: SpaceMapPurpose
        let reclaimReason: SpaceMapReclaimReason?
    }

    fileprivate let rulesByPath: [String: Classification]

    var explicitDirectoryCount: Int { rulesByPath.count }

    func purpose(atPath path: String) -> SpaceMapPurpose {
        nearestRule(atPath: path)?.purpose ?? .other
    }

    func reclaimReason(atPath path: String) -> SpaceMapReclaimReason? {
        nearestRule(atPath: path)?.reclaimReason
    }

    private func nearestRule(atPath rawPath: String) -> Classification? {
        var path = DiskScanner.storageMapLogicalPath(rawPath)
        while true {
            if let rule = rulesByPath[path] { return rule }
            let parent = DiskScanner.storageMapParentPath(path)
            if parent == path { return nil }
            path = parent
        }
    }
}

enum SpaceMapPurposeClassifier {
    static func classify(
        index: StorageMapAnalysisIndex,
        homePath rawHomePath: String,
        isCancelled: () -> Bool = { false }
    ) -> SpaceMapPurposeMap? {
        guard !isCancelled() else { return nil }
        let homePath = DiskScanner.storageMapLogicalPath(rawHomePath)
        let catalog = catalogReasons()
        var facts: [String: DirectoryFacts] = [:]
        var children: [String: [String]] = [:]
        var blockedSubtrees = [index.rootPath: index.blockedDirectoryPaths.contains(index.rootPath)]
        var processed = 0
        // Directory aggregates already contain the snapshot's byte counts.
        // Build only directory relationships, without allocating file paths or
        // materializing a treemap entry for every file just to classify it.
        for (path, aggregate) in index.directories {
            processed += 1
            if processed.isMultiple(of: 1_024), isCancelled() { return nil }
            let parent = DiskScanner.storageMapParentPath(path)
            guard path == index.rootPath || !isInBlockedSubtree(parent, index: index, cache: &blockedSubtrees) else {
                continue
            }
            let name = (path as NSString).lastPathComponent.lowercased()
            facts[path] = DirectoryFacts(name: name, bytes: aggregate.sizeBytes, namedPurpose: purpose(ofName: name))
            if path != index.rootPath {
                if index.directories[parent] != nil { children[parent, default: []].append(path) }
            }
        }
        // A bare repository needs both directory branches. Most directories
        // therefore never need to examine any of their filenames at all.
        for (path, childPaths) in children {
            processed += 1
            if processed.isMultiple(of: 1_024), isCancelled() { return nil }
            guard let directory = facts[path], directory.namedPurpose == nil,
                  childPaths.contains(where: { facts[$0]?.name == "objects" }),
                  childPaths.contains(where: { facts[$0]?.name == "refs" }),
                  index.childrenByDirectory[path]?.contains(where: {
                      $0.name.caseInsensitiveCompare("HEAD") == .orderedSame
                  }) == true else { continue }
            facts[path] = DirectoryFacts(name: directory.name, bytes: directory.bytes, namedPurpose: .git)
        }

        var rules: [String: SpaceMapPurposeMap.Classification] = [:]
        // The selected analysis root can itself be inside a synced folder.
        let startsInSync = isWithinSyncRoot(index.rootPath, homePath: homePath)
        let rootIsVolume = index.rootPath == "/" || DiskScanner.storageMapParentPath(index.rootPath) == "/Volumes"
        var stack = [Context(path: index.rootPath, purpose: .other, reclaimReason: nil,
                             protected: false, inSyncedDirectory: startsInSync)]
        while let context = stack.popLast() {
            processed += 1
            if processed.isMultiple(of: 1_024), isCancelled() { return nil }
            guard let directory = facts[context.path] else { continue }
            let parent = DiskScanner.storageMapParentPath(context.path)
            let topLevel = context.path != index.rootPath && (parent == index.rootPath || parent == homePath)
            let structural = parent == homePath && homeStructuralDirectoryNames.contains(directory.name)
                || parent == index.rootPath && rootIsVolume && volumeStructuralDirectoryNames.contains(directory.name)
            let ownPurpose = directory.namedPurpose ?? (topLevel && !structural
                ? dominantPurpose(below: context.path, facts: facts, children: children) : nil)
            let purpose = ownPurpose ?? context.purpose
            let startsProtection = directory.name == "archives" && facts[parent]?.name == "xcode"
                || directory.name == "backup" && facts[parent]?.name == "mobilesync"
            let protected = context.protected || startsProtection
            let inSyncedDirectory = context.inSyncedDirectory
                || isSyncRoot(named: directory.name, parent: parent, homePath: homePath)
            let isSyncHistory = directory.name == ".stversions"
            let ownReason: SpaceMapReclaimReason?
            if inSyncedDirectory {
                ownReason = isSyncHistory ? .syncHistory : nil
            } else {
                let catalogReason = relativePath(context.path, in: homePath).flatMap { catalog[$0.lowercased()] }
                ownReason = catalogReason ?? reclaimReason(
                    ofName: directory.name, parentPurpose: context.purpose,
                    siblings: index.childrenByDirectory[parent] ?? []
                )
            }
            // History remains identifiable even outside a sync root, below a cache.
            let inheritedReason = (inSyncedDirectory || isSyncHistory) && context.reclaimReason != .syncHistory
                ? nil : context.reclaimReason
            let reason = protected ? nil : inheritedReason ?? ownReason
            if ownPurpose != nil || ownReason != nil || startsProtection {
                rules[context.path] = .init(purpose: purpose, reclaimReason: reason)
            }
            for child in children[context.path] ?? [] {
                stack.append(Context(path: child, purpose: purpose, reclaimReason: reason,
                                     protected: protected, inSyncedDirectory: inSyncedDirectory))
            }
        }
        guard !isCancelled() else { return nil }
        return SpaceMapPurposeMap(rulesByPath: rules)
    }

    private struct DirectoryFacts: Sendable {
        let name: String
        let bytes: Int64
        let namedPurpose: SpaceMapPurpose?
    }

    private struct Context: Sendable {
        let path: String
        let purpose: SpaceMapPurpose
        let reclaimReason: SpaceMapReclaimReason?
        let protected: Bool
        let inSyncedDirectory: Bool
    }

    /// Cache ancestor decisions so blocked descendants get neither facts nor
    /// child relationships, regardless of the directory dictionary's order.
    private static func isInBlockedSubtree(
        _ path: String,
        index: StorageMapAnalysisIndex,
        cache: inout [String: Bool]
    ) -> Bool {
        var current = path
        var pending: [String] = []
        while cache[current] == nil {
            if index.blockedDirectoryPaths.contains(current) {
                cache[current] = true
                break
            }
            pending.append(current)
            let parent = DiskScanner.storageMapParentPath(current)
            if parent == current {
                cache[current] = false
                break
            }
            current = parent
        }
        let blocked = cache[current] ?? false
        for ancestor in pending { cache[ancestor] = blocked }
        return blocked
    }

    private static let homeStructuralDirectoryNames: Set<String> = ["library", "applications", "developer"]

    private static let volumeStructuralDirectoryNames: Set<String> = [
        "library", "applications", "system", "users", "private", "volumes",
        "opt", "usr", "bin", "sbin", "cores", "network", "developer"
    ]

    private static func isSyncRoot(named name: String, parent: String, homePath: String) -> Bool {
        name == "mobile documents" || name == "cloudstorage"
            || parent == homePath && purpose(ofName: name) == .synced
    }

    private static func isWithinSyncRoot(_ path: String, homePath: String) -> Bool {
        var current = path
        while true {
            let parent = DiskScanner.storageMapParentPath(current)
            let name = (current as NSString).lastPathComponent.lowercased()
            if isSyncRoot(named: name, parent: parent, homePath: homePath) { return true }
            guard parent != current else { return false }
            current = parent
        }
    }

    private static let agentNames: Set<String> = {
        let names: Set<String> = [
            ".codex", ".claude", ".cursor", ".aider", ".gemini", ".continue", ".windsurf",
            ".microsandbox", ".agents", ".openai", "tries", "worktrees", "sc-worktrees",
            "experiments", "scratch", "playground"
        ]
        let catalogRoots = DeveloperToolArtifactCatalog.definitions.compactMap { definition -> String? in
            switch definition.tool {
            case .codex, .claudeCode, .claudeDesktop, .cursor, .githubCopilot, .openCode,
                 .openClaw, .workBuddy, .windsurf, .continueDev: break
            default: return nil
            }
            let components = definition.rootPath.split(separator: "/")
            guard let first = components.first else { return nil }
            if first.hasPrefix("."), first != ".cache", first != ".local" { return first.lowercased() }
            if components.count >= 3,
               (components[0] == "Library" && components[1] == "Application Support"
                || components[0] == ".local" && components[1] == "share") {
                return components[2].lowercased()
            }
            return nil
        }
        return names.union(catalogRoots)
    }()

    private static func purpose(ofName name: String) -> SpaceMapPurpose? {
        if agentNames.contains(name) { return .agentWorkspace }
        if name.hasPrefix("onedrive - ") || name.hasPrefix("dropbox (") { return .synced }
        if (name as NSString).pathExtension == "photoslibrary" { return .media }
        switch name {
        case "src", "code", "projects", "repos", "dev", "work", "workspace", "workspaces",
             "github.com", "gitlab.com", "sites", "development": return .code
        case ".cargo", ".rustup", ".local", ".npm", ".pnpm-store", "pnpm", ".bun", ".deno", "go",
             ".gradle", ".m2", ".platformio", "mise", ".mise", ".pyenv", ".nvm", ".gem", "gem",
             ".rbenv", ".espressif", ".arduino15", ".config", ".vscode", ".zig", ".rye", ".conda",
             "anaconda3", "miniconda3", ".opam", ".ghcup", ".stack", ".julia", ".dotnet", ".android",
             ".sdkman", ".volta", ".yarn", ".java", ".nuget", "xcode", "coresimulator": return .toolchain
        case "sync", "dropbox", "nextcloud", "google drive", "onedrive", "pclouddrive", "mega",
             ".stversions", "mobile documents", "cloudstorage": return .synced
        case ".git": return .git
        case "pictures", "photos", "music", "videos", "movies", "steam", "steamlibrary", "steamapps",
             "emulation", "models", ".ollama", ".lmstudio", "games", "wineprefix": return .media
        case "documents", "desktop", "downloads", "books", "notes", "obsidian", "public", "templates":
            return .documents
        case ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache", "__pycache__",
             "node_modules", "trash", ".trash", ".trashes", "tmp", ".tmp", "deriveddata", "ios devicesupport",
             "watchos devicesupport": return .cache
        default: return nil
        }
    }

    private static func reclaimReason(
        ofName name: String,
        parentPurpose: SpaceMapPurpose,
        siblings: [StorageMapIndexedEntry]
    ) -> SpaceMapReclaimReason? {
        func has(_ wanted: String) -> Bool {
            // Compare existing names, allocating neither lowercased filenames
            // nor a sibling-name set that grows with the number of files.
            siblings.contains { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        switch name {
        case ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache",
             "ios devicesupport", "watchos devicesupport": return .regenerableCache
        case ".stversions": return .syncHistory
        case ".pnpm-store", "pnpm": return .packageStore
        case "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next", ".turbo",
             ".parcel-cache", "deriveddata": return .buildOutput
        case "target" where has("Cargo.toml"): return .buildOutput
        case ".build" where has("Package.swift"): return .buildOutput
        case "build" where has("build.gradle") || has("build.gradle.kts"): return .buildOutput
        case "node_modules" where has("package.json"): return .reinstallableDependencies
        case "pods" where has("Podfile"): return .reinstallableDependencies
        case ".venv", "venv":
            return has("pyproject.toml") || has("requirements.txt") || has("setup.py")
                ? .reinstallableDependencies : nil
        case "logs" where has("Application Support"): return .logs
        case "layers" where parentPurpose == .agentWorkspace: return .sandboxLayers
        case "snapshots" where parentPurpose == .agentWorkspace: return .snapshots
        case "trash", ".trash", ".trashes": return .trash
        case "tmp", ".tmp": return .temporary
        default: return nil
        }
    }

    private static func catalogReasons() -> [String: SpaceMapReclaimReason] {
        var reasons: [String: SpaceMapReclaimReason] = [:]
        for definition in DeveloperToolArtifactCatalog.definitions {
            let reason: SpaceMapReclaimReason
            if definition.policy == .disposableLogs || definition.kind == .logs {
                reason = .logs
            } else if definition.kind == .temporaryFiles {
                reason = .temporary
            } else if definition.policy == .regenerable {
                reason = .regenerableCache
            } else {
                continue
            }
            for candidate in definition.candidateNames {
                reasons[(definition.rootPath + "/" + candidate).lowercased()] = reason
            }
        }
        return reasons
    }

    private static func relativePath(_ path: String, in home: String) -> String? {
        guard path != home, DiskScanner.storageMapPath(path, isWithinRoot: home) else { return nil }
        return String(path.dropFirst(home == "/" ? 1 : home.count + 1))
    }

    /// Follow only the largest directory for at most three levels. A known
    /// name/shape must account for at least half of the original top-level bytes.
    private static func dominantPurpose(
        below path: String,
        facts: [String: DirectoryFacts],
        children: [String: [String]]
    ) -> SpaceMapPurpose? {
        guard let topLevelBytes = facts[path]?.bytes, topLevelBytes > 0 else { return nil }
        var current = path
        for _ in 0..<3 {
            var largest: String?
            for child in children[current] ?? [] {
                if isLarger(child, than: largest, facts: facts) { largest = child }
            }
            guard let largest, let candidate = facts[largest] else { return nil }
            let (doubledBytes, overflow) = max(0, candidate.bytes).multipliedReportingOverflow(by: 2)
            if let purpose = candidate.namedPurpose, overflow || doubledBytes >= topLevelBytes {
                return purpose
            }
            current = largest
        }
        return nil
    }

    private static func isLarger(_ path: String, than other: String?, facts: [String: DirectoryFacts]) -> Bool {
        guard let other else { return true }
        let bytes = facts[path]?.bytes ?? 0
        let otherBytes = facts[other]?.bytes ?? 0
        return bytes == otherBytes ? path < other : bytes > otherBytes
    }
}
