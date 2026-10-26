import Darwin
import Foundation

struct ProjectArtifactScanLimits: Sendable {
    var maximumDepth = 12
    var maximumEntries = 100_000
    var maximumProjects = 500
    var maximumArtifactEntries = 100_000
    var maximumArtifactDepth = 32
    var maximumDuration: TimeInterval = 60
    var maximumArtifactDuration: TimeInterval = 10
}

/// All I/O runs in a detached cancellable worker. No scripts/build tools are executed.
struct ProjectArtifactScanner: Sendable {
    var fileSystem: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem()
    var limits = ProjectArtifactScanLimits()
    var home = FileManager.default.homeDirectoryForCurrentUser
    var excludedURLs: [URL] = []
    var ignoreList: IgnoreListSnapshot = .empty

    func scan(roots: [URL], now: Date = Date()) async throws -> ProjectArtifactScanResult {
        let worker = Task.detached(priority: .utility) { try scanSynchronously(roots: roots, now: now) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    func scanSynchronously(roots: [URL], now: Date = Date()) throws -> ProjectArtifactScanResult {
        let home = home.standardizedFileURL
        let excludedURLs = self.excludedURLs + ignoreList.paths(for: .systemJunk).map { URL(fileURLWithPath: $0) }
        var ignoredPaths = Set<String>()
        var queue = roots.map { ($0.standardizedFileURL, 0, Optional<URL>.none) }
        var seen = Set<String>(), projects = Set<URL>(), times = [URL: Date]()
        var raw = [(URL, ProjectArtifactRequirement, FileSnapshot, FileSnapshot, String?, CleanupReclaimableEstimate?)]()
        var claimedArtifacts = Set<FileIdentity>()
        var scopeWarnings = [String]()
        var visited = 0, limited = false
        var incompleteProjects = Set<URL>()
        func markIncomplete(_ directory: URL) {
            limited = true
            for project in projects where PathSafety.isContained(directory.path, in: project.path, resolvingSymlinks: false) {
                incompleteProjects.insert(project)
            }
        }
        let deadline = Date().addingTimeInterval(limits.maximumDuration)
        while let (directory, depth, inheritedProject) = queue.popLast() {
            try Task.checkCancellation()
            guard seen.insert(directory.path).inserted else { continue }
            guard Date() < deadline, visited < limits.maximumEntries, projects.count < limits.maximumProjects else { markIncomplete(directory); for pending in queue { markIncomplete(pending.0) }; break }
            if ScanExclusionService.isExcluded(directory.path, excludedPaths: excludedURLs.map(\.path)) {
                ignoredPaths.insert(PathSafety.normalizedPath(directory.path)); continue
            }
            // No default home scan, no traversal of a selected cloud/symlink root.
            guard directory.path != home.path,
                  PathSafety.isContained(directory.path, in: home.path, resolvingSymlinks: false),
                  !Self.isCloudPath(directory),
                  !ScanExclusionService.isExcluded(directory.path, excludedPaths: excludedURLs.map(\.path)) else {
                markIncomplete(directory); scopeWarnings.append("\(directory.path)：家目录根、云盘或排除范围，仅显示，未遍历")
                continue
            }
            // Installed payloads cannot become projects, including a selected root's ancestors.
            if isInstalledPayload(directory) {
                scopeWarnings.append("\(directory.path)：已安装依赖或扩展位置，未遍历")
                continue
            }
            let snapshot: FileSnapshot
            do { snapshot = try fileSystem.snapshot(at: directory) } catch { markIncomplete(directory); continue }
            guard snapshot.identity.entryKind == .directory, !snapshot.hasSymbolicLinkComponent,
                  !snapshot.isCloudItem, !snapshot.isCloudPlaceholder else { markIncomplete(directory); continue }
            if let parent = inheritedProject,
               let parentSnapshot = try? fileSystem.snapshot(at: parent),
               parentSnapshot.volumeIdentifier != snapshot.volumeIdentifier { markIncomplete(directory); continue }
            let children: [URL]
            do { children = try fileSystem.children(of: directory) } catch { markIncomplete(directory); continue }
            let definitions = try requirements(at: directory)
            let project = definitions.isEmpty ? inheritedProject : directory
            if !definitions.isEmpty { projects.insert(directory) }
            if let project { times[project] = max(times[project] ?? .distantPast, date(snapshot.modificationTimeNanoseconds) ?? .distantFuture) }
            var artifactPaths = Set<String>()
            var candidates = definitions
            // Python bytecode/test/type caches may sit below the manifest root.
            if definitions.isEmpty, let project,
               let python = try requirements(at: project).first(where: { $0.ecosystem == "Python" }) {
                candidates = ProjectArtifactRequirement.catalog.filter { ["__pycache__", ".pytest_cache", ".mypy_cache"].contains($0.relativeArtifact) }.map {
                    .init(ecosystem: "Python", manifest: python.manifest,
                        relativeArtifact: relative(directory.appendingPathComponent($0.relativeArtifact), to: project),
                        rebuildCommand: $0.rebuildCommand, evidenceURL: $0.evidenceURL, revision: $0.revision, checkedAt: $0.checkedAt, lockEvidence: python.lockEvidence)
                }
            }
            if let project {
                for requirement in candidates {
                    try Task.checkCancellation()
                    guard Date() < deadline, raw.count < 1_500 else { markIncomplete(directory); break }
                    let artifact = project.appendingPathComponent(requirement.relativeArtifact)
                    // Missing artifacts are not candidates; metadata only, never follow links.
                    guard let rootSnapshot = try? fileSystem.snapshot(at: artifact) else { continue }
                    guard rootSnapshot.identity.entryKind == .directory || rootSnapshot.identity.entryKind == .symbolicLink else { continue }
                    artifactPaths.insert(PathSafety.lexicalPath(artifact.path))
                    if ScanExclusionService.intersectsExcludedTree(artifact.path, excludedPaths: excludedURLs.map(\.path)) {
                        ignoredPaths.insert(PathSafety.normalizedPath(artifact.path)); continue
                    }
                    // Mixed-ecosystem projects can name the same build folder.
                    // First catalog rule claims the identity, like the D82 scanner.
                    guard claimedArtifacts.insert(rootSnapshot.identity).inserted else { continue }
                    // D104 G1: what emptying the Trash frees, read while the artifact is measured.
                    var sharing: CleanupReclaimableTally? = CleanupReclaimableTally()
                    let assessment = assess(artifact: artifact, project: project, requirement: requirement, sharing: &sharing)
                    if let modified = date(assessment.snapshot?.modificationTimeNanoseconds ?? rootSnapshot.modificationTimeNanoseconds) {
                        times[project] = max(times[project] ?? .distantPast, modified)
                    }
                    raw.append((project, requirement, rootSnapshot, assessment.snapshot ?? rootSnapshot, assessment.reason,
                        assessment.reason == nil ? sharing?.estimate : nil))
                }
            }
            for child in children {
                try Task.checkCancellation()
                visited += 1
                guard visited <= limits.maximumEntries else { markIncomplete(directory); break }
                let name = child.lastPathComponent.lowercased()
                // Skip artifact internals, credentials, repository state and cloud roots.
                if artifactPaths.contains(PathSafety.lexicalPath(child.path)) || name == ".git" || name.hasPrefix(".env") || Self.isCloudPath(child) { continue }
                // Confirmed artifacts were skipped above; generic ancestor names are not installation evidence.
                if isInstalledPayload(child) || [".xcodeproj", ".xcworkspace"].contains("." + child.pathExtension) { continue }
                guard let entry = try? fileSystem.snapshot(at: child) else { markIncomplete(directory); continue }
                guard entry.identity.entryKind != .symbolicLink, !entry.hasSymbolicLinkComponent,
                      entry.volumeIdentifier == snapshot.volumeIdentifier else { continue }
                if let project { times[project] = max(times[project] ?? .distantPast, date(entry.modificationTimeNanoseconds) ?? .distantFuture) }
                if entry.identity.entryKind == .directory {
                    if depth < limits.maximumDepth { queue.append((child, depth + 1, project)) }
                    else { markIncomplete(child) }
                }
            }
        }
        try Task.checkCancellation()
        // Workspace activity propagates to each containing project, even without workspaces metadata.
        for (child, modified) in times {
            for parent in projects where parent != child && PathSafety.isContained(child.path, in: parent.path, resolvingSymlinks: false) {
                times[parent] = max(times[parent] ?? .distantPast, modified)
            }
        }
        let id = ScanSessionID()
        let rules = CleanupRuleSet(schemaVersion: 2, rulesVersion: "project-artifacts.1", rules: raw.map { $0.1.rule(project: $0.0, home: home) })
        let provenance = rules.effectiveProvenance
        let rows = zip(raw, rules.rules).map { entry, rule -> ProjectArtifactRow in
            let (project, requirement, _, measured, blocked, reclaimable) = entry
            let source = project.appendingPathComponent(requirement.relativeArtifact)
            let reason = blocked
            let candidate = ScanCandidate(id: ScanCandidateID(), sessionID: id, ruleID: rule.id,
                ruleSelectionPolicyVersion: rule.selectionPolicyVersion, categoryID: rule.categoryID,
                categoryTitle: "项目产物", subcategoryTitle: project.lastPathComponent,
                sourceURL: source, allowedRootURL: project, snapshot: measured, risk: rule.risk,
                recommendation: .init(level: rule.recommendation, reasonCode: rule.reasonKey, evidenceCodes: [requirement.manifest, requirement.evidenceURL]),
                defaultSelection: .unselected, executionEligibility: reason == nil ? rule.executionEligibility : .advisoryOnly,
                measurementCompleteness: reason == nil ? .complete : .lowerBound(reason: .unknown),
                isManuallySelectable: reason == nil, action: reason == nil ? rule.action : .revealOnly,
                requiredClosedBundleIDs: [], reason: reason ?? "由项目清单确认，产物可重建；默认不预选",
                latestContentModificationTimeNanoseconds: measured.modificationTimeNanoseconds,
                ownerResolution: .noApplication, ruleRevision: rule.maintenance?.revision,
                rulesProvenance: provenance, cleanupImpactText: rule.maintenance?.impact, reclaimableEstimate: reclaimable)
            return .init(project: project, requirement: requirement, candidate: candidate, blockedReason: reason, projectModifiedAt: incompleteProjects.contains(project) ? nil : times[project])
        }
        let session = ScanSession(id: id, rulesVersion: rules.rulesVersion, startedAt: now, completedAt: Date(), outcome: limited ? .partial : .complete,
            categories: [.init(id: "project-artifacts", title: "项目产物", subcategories: [.init(id: "project-artifacts", title: "项目产物", risk: .reviewOnly, recommendation: .optional, reason: "默认不预选", candidates: rows.map(\.candidate))])],
            issues: [], permissions: [], metrics: .init(ignoredItemCount: ignoredPaths.count, visitedEntryCount: visited, candidateCount: rows.count, deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: CleanupByteCount.sum(rows.map { $0.candidate.estimatedSizeBytes }), duration: Date().timeIntervalSince(now)), rulesProvenance: provenance)
        return .init(rows: rows, rules: rules, session: session, limited: limited, scopeWarnings: scopeWarnings)
    }

    func requirements(at project: URL) throws -> [ProjectArtifactRequirement] {
        guard !isInstalledPayload(project) else { return [] }
        var result = [ProjectArtifactRequirement]()
        for prototype in ProjectArtifactRequirement.catalog {
            try Task.checkCancellation()
            let manifests: [String]
            switch prototype.ecosystem {
            case "Python": manifests = ["pyproject.toml", "requirements.txt", "setup.py"]
            case "Gradle": manifests = ["build.gradle", "build.gradle.kts"]
            default: manifests = [prototype.manifest]
            }
            guard let manifest = manifests.first(where: { regularFile(project.appendingPathComponent($0)) }) else { continue }
            if prototype.ecosystem == "npm", prototype.relativeArtifact != "node_modules" {
                guard let text = try? readSmallFile(project.appendingPathComponent(manifest)),
                      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let scripts = object["scripts"] as? [String: String], let build = scripts["build"], !build.isEmpty else { continue }
                let artifact = prototype.relativeArtifact
                let confirmsOutput = confirmsNodeOutput(build: build, artifact: artifact, project: project)
                guard confirmsOutput else { continue }
            }
            if prototype.ecosystem == "Bundler" {
                guard let config = try? readSmallFile(project.appendingPathComponent(".bundle/config")),
                      config.split(separator: "\n").contains(where: { line in
                          let pieces = line.split(separator: ":", maxSplits: 1)
                          return pieces.count == 2 && pieces[0].trimmingCharacters(in: .whitespaces) == "BUNDLE_PATH"
                              && pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")) == "vendor/bundle"
                      }) else { continue }
            }
            result.append(.init(ecosystem: prototype.ecosystem, manifest: manifest, relativeArtifact: prototype.relativeArtifact,
                rebuildCommand: prototype.rebuildCommand, evidenceURL: prototype.evidenceURL, revision: prototype.revision, checkedAt: prototype.checkedAt, lockEvidence: lockEvidence(at: project, ecosystem: prototype.ecosystem)))
        }
        return result
    }

    func assess(artifact: URL, project: URL, requirement: ProjectArtifactRequirement) -> (snapshot: FileSnapshot?, reason: String?) {
        var sharing: CleanupReclaimableTally?
        return assess(artifact: artifact, project: project, requirement: requirement, sharing: &sharing)
    }

    /// D104 G1: `sharing`, when given, tallies how much of each regular file
    /// deleting it frees (`FileStorageSharing`), once per file like the
    /// sizes. Nil (the executor's recheck) reads nothing extra.
    private func assess(artifact: URL, project: URL, requirement: ProjectArtifactRequirement,
                        sharing: inout CleanupReclaimableTally?) -> (snapshot: FileSnapshot?, reason: String?) {
        if ScanExclusionService.intersectsExcludedTree(artifact.path, excludedPaths: excludedURLs.map(\.path)) { return (nil, "用户排除的位置，仅显示") }
        if Self.isCloudPath(artifact) { return (nil, "云盘位置，仅显示；不读取内容或触发同步删除") }
        guard let root = try? fileSystem.snapshot(at: artifact), let projectRoot = try? fileSystem.snapshot(at: project) else { return (nil, "目录不可读") }
        if root.identity.entryKind == .symbolicLink || root.hasSymbolicLinkComponent { return (nil, "符号链接，仅显示") }
        if root.volumeIdentifier != projectRoot.volumeIdentifier { return (nil, "跨卷目录，仅显示") }
        if root.isCloudItem || root.isCloudPlaceholder { return (nil, "云盘位置，仅显示") }
        if requirement.relativeArtifact == ".venv" || requirement.relativeArtifact == "venv" {
            guard regularFile(artifact.appendingPathComponent("pyvenv.cfg")) else { return (nil, "缺少 pyvenv.cfg，无法确认虚拟环境") }
            guard venvInterpreterHome(artifact) != nil else { return (nil, "pyvenv.cfg 的 home 无法解析，仅显示") }
        }
        guard root.identity.entryKind == .directory else { return (nil, "不是产物目录") }
        let git = ProjectArtifactGitSafety.check(project: artifact.deletingLastPathComponent(), artifact: artifact)
        guard git == .ignored || git == .noRepository else { return (nil, git.message) }
        if git == .noRepository && !hasGeneratedMarker(artifact: artifact, requirement: requirement) {
            return (nil, "非 Git 项目缺少工具生成标记，无法确认可再生产物，仅显示")
        }
        var stack = [(artifact, 0)], count = 0, logical: Int64 = 0, allocated: Int64? = 0, latest: Int64? = nil
        var identities = Set<FileIdentity>()
        let deadline = Date().addingTimeInterval(limits.maximumArtifactDuration)
        while let (url, depth) = stack.popLast() {
            if Task.isCancelled { return (nil, "扫描已取消") }
            count += 1
            guard Date() < deadline, count <= limits.maximumArtifactEntries, depth <= limits.maximumArtifactDepth else { return (nil, "产物测量达到上限，仅显示") }
            // aggregateSnapshot uses lstat; internal links never query target metadata.
            guard let measurement = try? fileSystem.aggregateSnapshot(at: url) else { return (nil, "产物大小或时间不可读，仅显示") }
            let entry: FileSnapshot
            if measurement.identity.entryKind == .symbolicLink { entry = measurement }
            else {
                guard let full = try? fileSystem.snapshot(at: url) else { return (nil, "产物包含不可读项目，仅显示") }
                entry = full
            }
            if url != artifact && (protectedArtifactName(url.lastPathComponent, requirement: requirement) || Self.protectsProjectSource(url, requirement: requirement)) { return (nil, "产物包含源码、配置、锁文件或用户数据保护标记，仅显示") }
            // Moving the containing directory never follows these links. Measure the link itself.
            if entry.identity.entryKind == .symbolicLink {
                guard allowsInternalLink(url, artifact: artifact, requirement: requirement) else { return (nil, "产物包含指向外部的符号链接，仅显示") }
                logical = CleanupByteCount.adding(entry.logicalSizeBytes, to: logical)
                if let current = allocated, let size = entry.allocatedSizeBytes { allocated = CleanupByteCount.adding(size, to: current) } else { allocated = nil }
                if let value = entry.modificationTimeNanoseconds { latest = max(latest ?? value, value) } else { return (nil, "修改时间不可读，仅显示") }
                continue
            }
            if entry.hasSymbolicLinkComponent { return (nil, "产物包含符号链接祖先，仅显示") }
            if entry.volumeIdentifier != root.volumeIdentifier { return (nil, "产物包含跨卷目录，仅显示") }
            if Self.isCloudPath(url) || entry.isCloudItem || entry.isCloudPlaceholder { return (nil, "产物包含云文件，仅显示") }
            if !identities.insert(entry.identity).inserted { continue }
            logical = CleanupByteCount.adding(measurement.logicalSizeBytes, to: logical)
            if let current = allocated, let size = measurement.allocatedSizeBytes { allocated = CleanupByteCount.adding(size, to: current) } else { allocated = nil }
            if entry.identity.entryKind == .regularFile {
                sharing?.record(fileSystem.storageSharing(at: url),
                    allocatedBytes: measurement.allocatedSizeBytes ?? measurement.logicalSizeBytes, deviceID: entry.identity.deviceID)
            }
            if let value = measurement.modificationTimeNanoseconds { latest = max(latest ?? value, value) } else { return (nil, "修改时间不可读，仅显示") }
            if entry.identity.entryKind == .directory {
                guard let children = try? fileSystem.children(of: url) else { return (nil, "产物包含不可读目录，仅显示") }
                stack.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return (FileSnapshot(identity: root.identity, standardizedPath: root.standardizedPath, volumeIdentifier: root.volumeIdentifier,
            logicalSizeBytes: logical, allocatedSizeBytes: allocated, modificationTimeNanoseconds: latest,
            isWritableVolume: root.isWritableVolume, isCloudItem: false, isCloudPlaceholder: false, hasSymbolicLinkComponent: false), nil)
    }

    static let artifactContainerNames: Set<String> = Set(ProjectArtifactRequirement.catalog.map { URL(fileURLWithPath: $0.relativeArtifact).lastPathComponent }).union(["vendor", "venv", ".venv"])
    static func isCloudPath(_ url: URL) -> Bool {
        let components = url.pathComponents.map { $0.lowercased() }
        return components.contains("mobile documents") || components.contains("cloudstorage") || components.contains("icloud")
            || components.contains("dropbox") || components.contains("google drive") || components.contains("onedrive")
    }
    static func protectedName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == ".git" || lower.hasPrefix(".env")
            || ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock", "poetry.lock", "uv.lock", "pipfile.lock", "gemfile.lock", "composer.lock", "pubspec.lock", "package.resolved", ".npmrc", ".pypirc", "credentials", "secrets", "userdata"].contains(lower)
            || ["sqlite", "sqlite3", "db", "key", "pem"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }
    static func protectsProjectSource(_ url: URL, requirement: ProjectArtifactRequirement) -> Bool {
        // Dependency directories intentionally contain reproducible dependency
        // sources/configuration. Generic build outputs must never absorb a
        // project's hand-maintained sources or configuration instead.
        guard ["dist", "build", "target"].contains(requirement.relativeArtifact) else { return false }
        if ["src", "source", "sources", "config"].contains(url.lastPathComponent.lowercased()) { return true }
        // Known generated source layouts stay rebuildable; hand-maintained source remains protected.
        if requirement.relativeArtifact == "target" { return false }
        if url.lastPathComponent.hasSuffix(".d.ts") { return false }
        if requirement.ecosystem == "npm", requirement.relativeArtifact == "build", url.pathExtension == "js",
           !url.pathComponents.contains("static"), !url.pathComponents.contains("assets") { return true }
        return ["icns", "plist", "swift", "rs", "py", "ts", "tsx", "c", "cpp", "h", "java", "kt", "rb", "php", "dart", "toml", "ini", "conf"].contains(url.pathExtension.lowercased())
    }
    private func isInstalledPayload(_ url: URL) -> Bool {
        let parts = url.pathComponents.map { $0.lowercased() }
        if parts.contains(where: { ["node_modules", "site-packages", "dist-packages", ".npm"].contains($0) }) { return true }
        for index in parts.indices {
            if [".vscode", ".vscode-insiders", ".cursor", ".windsurf"].contains(parts[index]), parts.dropFirst(index + 1).first == "extensions" { return true }
            if parts[index] == ".cargo", parts.dropFirst(index + 1).first == "registry" { return true }
        }
        // Custom-named venv roots also contain installed payloads.
        var ancestor = url
        while ancestor.path != "/" {
            if regularFile(ancestor.appendingPathComponent("pyvenv.cfg")) { return true }
            if ancestor.lastPathComponent.lowercased() == "vendor", regularFile(ancestor.appendingPathComponent("composer/installed.json")) { return true }
            if ancestor.lastPathComponent.lowercased() == "bundle", ancestor.deletingLastPathComponent().lastPathComponent.lowercased() == "vendor",
               hasBundlerSpecifications(in: ancestor) { return true }
            ancestor.deleteLastPathComponent()
        }
        return false
    }

    private func protectedArtifactName(_ name: String, requirement: ProjectArtifactRequirement) -> Bool {
        if ["node_modules", ".venv", "venv", ".build", "vendor", "vendor/bundle", ".gradle", ".dart_tool"].contains(requirement.relativeArtifact) {
            let lower = name.lowercased()
            return lower == ".git" || lower.hasPrefix(".env") || ["credentials", "secrets", "userdata", ".npmrc", ".pypirc"].contains(lower)
        }
        return Self.protectedName(name)
    }

    private func allowsInternalLink(_ url: URL, artifact: URL, requirement: ProjectArtifactRequirement) -> Bool {
        guard let destination = try? fileSystem.symbolicLinkDestination(of: url) else { return false }
        let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : url.deletingLastPathComponent().appendingPathComponent(destination)
        if PathSafety.isContained(target.standardizedFileURL.path, in: artifact.standardizedFileURL.path, resolvingSymlinks: false) { return true }
        // venv's interpreter is intentionally external; no other external link is allowed.
        guard [".venv", "venv"].contains(requirement.relativeArtifact),
              url.deletingLastPathComponent().standardizedFileURL.path == artifact.appendingPathComponent("bin").standardizedFileURL.path,
              url.lastPathComponent.range(of: #"^python([0-9]+(\.[0-9]+)*)?$"#, options: .regularExpression) != nil else { return false }
        guard let home = venvInterpreterHome(artifact),
              target.lastPathComponent.range(of: #"^python([0-9]+(\.[0-9]+)*)?$"#, options: .regularExpression) != nil else { return false }
        let resolvedTarget = target.standardizedFileURL.resolvingSymlinksInPath()
        return resolvedTarget.lastPathComponent.range(of: #"^python([0-9]+(\.[0-9]+)*)?$"#, options: .regularExpression) != nil
            && PathSafety.isContained(resolvedTarget.path, in: home.resolvingSymlinksInPath().path, resolvingSymlinks: false)
    }

    private func venvInterpreterHome(_ artifact: URL) -> URL? {
        guard let config = try? readSmallFile(artifact.appendingPathComponent("pyvenv.cfg")) else { return nil }
        let homes = config.split(separator: "\n").compactMap { line -> String? in
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "home" else { return nil }
            return pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard homes.count == 1, let path = homes.first, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path != "/", !Self.isCloudPath(url) else { return nil }
        return url
    }

    private func hasBundlerSpecifications(in root: URL) -> Bool {
        // Bundler's versioned ruby installation writes specifications/*.gemspec.
        func localDirectory(_ url: URL) -> Bool {
            guard !Self.isCloudPath(url), let entry = try? fileSystem.snapshot(at: url) else { return false }
            return entry.identity.entryKind == .directory && !entry.hasSymbolicLinkComponent && !entry.isCloudItem && !entry.isCloudPlaceholder
        }
        let ruby = root.appendingPathComponent("ruby")
        guard localDirectory(ruby), let rubies = try? fileSystem.children(of: ruby), rubies.count <= 100 else { return false }
        return rubies.contains { version in
            let specifications = version.appendingPathComponent("specifications")
            guard localDirectory(version), localDirectory(specifications),
                  let specs = try? fileSystem.children(of: specifications), specs.count <= 10_000 else { return false }
            return specs.contains { $0.pathExtension == "gemspec" && regularFile($0) }
        }
    }

    private func hasGeneratedMarker(artifact: URL, requirement: ProjectArtifactRequirement) -> Bool {
        let markers: [String]
        switch artifact.lastPathComponent {
        case "node_modules": markers = [".package-lock.json", ".yarn-state.yml", ".modules.yaml"]
        case "target" where requirement.ecosystem == "Cargo": markers = ["CACHEDIR.TAG"]
        case ".build": markers = ["workspace-state.json", "debug.yaml", "release.yaml"]
        case ".venv", "venv": return venvInterpreterHome(artifact) != nil
        case "vendor" where requirement.ecosystem == "Composer": markers = ["composer/installed.json"]
        case "bundle" where requirement.ecosystem == "Bundler": return hasBundlerSpecifications(in: artifact)
        case ".dart_tool": markers = ["package_config.json"]
        case ".next": markers = ["BUILD_ID"]
        case ".pytest_cache": markers = ["CACHEDIR.TAG"]
        case ".mypy_cache": markers = ["CACHEDIR.TAG"]
        case "__pycache__":
            guard let children = try? fileSystem.children(of: artifact), !children.isEmpty else { return false }
            return children.allSatisfy { $0.pathExtension == "pyc" && regularFile($0) }
        default: return false
        }
        return markers.contains { regularFile(artifact.appendingPathComponent($0)) }
    }

    private func confirmsNodeOutput(build: String, artifact: String, project: URL) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: artifact)
        let flag = #"(?:^|[\s;&])(?:--outDir|--out-dir|--output|--dist-dir|-o)(?:\s+|=)["']?(?:\./)?"# + escaped + #"/?["']?(?=\s|$|[;&])"#
        if build.range(of: flag, options: .regularExpression) != nil { return true }
        // Only a literal output property in a known tool's small regular config is accepted.
        let tool: String
        if build.range(of: #"(?:^|[\s;&])vite\s+build(?:\s|$|[;&])"#, options: .regularExpression) != nil { tool = "vite" }
        else if build.range(of: #"(?:^|[\s;&])tsup(?:\s|$)"#, options: .regularExpression) != nil { tool = "tsup" }
        else if build.range(of: #"(?:^|[\s;&])next\s+build(?:\s|$|[;&])"#, options: .regularExpression) != nil { tool = "next" }
        else { tool = "" }
        var foundConfiguration = false
        for suffix in ["ts", "js", "mjs", "mts"] where !tool.isEmpty {
            let configURL = project.appendingPathComponent("\(tool).config.\(suffix)")
            guard (try? fileSystem.snapshot(at: configURL)) != nil else { continue }
            foundConfiguration = true
            guard let config = try? readSmallFile(configURL), !config.contains("//"), !config.contains("/*"),
                  !config.contains("..."), !config.contains("["), !config.contains("process."), !config.contains("require("),
                  !config.contains("import ") else { continue }
            let property = tool == "vite" ? #"build\s*:\s*\{\s*outDir"# : (tool == "next" ? #"\{\s*distDir"# : #"\{\s*outDir"#)
            if config.range(of: property + #"\s*:\s*["'](?:\./)?"# + escaped + #"/?["']\s*\}"#, options: .regularExpression) != nil { return true }
        }
        // An existing ambiguous/overriding config cannot justify the tool's default directory.
        if foundConfiguration { return false }
        let output = project.appendingPathComponent(artifact)
        guard let metadata = try? fileSystem.snapshot(at: output), metadata.identity.entryKind == .directory,
              !metadata.hasSymbolicLinkComponent, !metadata.isCloudItem, !metadata.isCloudPlaceholder else { return false }
        func productDirectory(_ name: String) -> Bool {
            guard let entry = try? fileSystem.snapshot(at: output.appendingPathComponent(name)) else { return false }
            return entry.identity.entryKind == .directory && !entry.hasSymbolicLinkComponent && !entry.isCloudItem && !entry.isCloudPlaceholder
        }
        if artifact == ".next" { return build.range(of: #"(?:^|[\s;&])next\s+build(?:\s|$|[;&])"#, options: .regularExpression) != nil && regularFile(output.appendingPathComponent("BUILD_ID")) && productDirectory("server") }
        if artifact == "dist", build.range(of: #"(?:^|[\s;&])vite\s+build(?:\s|$|[;&])"#, options: .regularExpression) != nil { return regularFile(output.appendingPathComponent("index.html")) && productDirectory("assets") }
        if artifact == "build", build.range(of: #"(?:^|[\s;&])react-scripts\s+build(?:\s|$|[;&])"#, options: .regularExpression) != nil { return regularFile(output.appendingPathComponent("index.html")) && productDirectory("static") }
        return false
    }

    private func lockEvidence(at project: URL, ecosystem: String) -> String {
        let locks: [String]
        switch ecosystem {
        case "npm": locks = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml"]
        case "Cargo": locks = ["Cargo.lock"]
        case "Python": locks = ["poetry.lock", "uv.lock", "Pipfile.lock"]
        case "Swift": locks = ["Package.resolved"]
        case "Bundler": locks = ["Gemfile.lock"]
        case "Composer": locks = ["composer.lock"]
        case "Dart": locks = ["pubspec.lock"]
        case "Gradle": locks = ["gradle.lockfile"]
        default: locks = []
        }
        let present = locks.filter { regularFile(project.appendingPathComponent($0)) }
        return present.isEmpty ? "未确认锁文件，重建可能取不同版本；清单外本地安装不能保证恢复" : "已确认锁文件：" + present.joined(separator: "、")
    }

    private func regularFile(_ url: URL) -> Bool {
        guard !Self.isCloudPath(url), let snapshot = try? fileSystem.snapshot(at: url) else { return false }
        return snapshot.identity.entryKind == .regularFile && !snapshot.hasSymbolicLinkComponent && !snapshot.isCloudItem && !snapshot.isCloudPlaceholder
    }
    private func readSmallFile(_ url: URL) throws -> String {
        guard regularFile(url), let snapshot = try? fileSystem.snapshot(at: url), snapshot.logicalSizeBytes <= 1_048_576 else { throw CleanupFileSystemError.unreadable }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw CleanupFileSystemError.unreadable }
        return text
    }
    private func date(_ nanoseconds: Int64?) -> Date? { nanoseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000) } }
    private func relative(_ url: URL, to root: URL) -> String {
        let rootPath = PathSafety.lexicalPath(root.path)
        let path = PathSafety.lexicalPath(url.path)
        return String(path.dropFirst(rootPath.count + 1))
    }
}

/// Git is the authoritative ignore parser: nested rules, negation, escaped
/// names, global excludes, worktrees and tracked-but-ignored entries all work.
enum ProjectArtifactGitSafety: Equatable {
    case noRepository, ignored, tracked, notIgnored, unknown
    var message: String {
        switch self {
        case .tracked: "Git 已跟踪产物内容，不可选"
        case .notIgnored: "Git 未忽略此产物，仅显示"
        case .unknown: "无法核对 Git 状态，仅显示"
        default: ""
        }
    }
    static func check(project: URL, artifact: URL, toolchainAvailable: Bool? = nil, configurationHome: URL? = nil) -> Self {
        var ancestor = project
        var repository = false
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) { repository = true; break }
            ancestor.deleteLastPathComponent()
        }
        guard repository else { return .noRepository }
        guard toolchainAvailable ?? hasToolchain() else { return .unknown }
        guard let tracked = run(project: project, configurationHome: configurationHome, arguments: ["ls-files", "-z", "--", artifact.path]), tracked.status == 0 else { return .unknown }
        guard !tracked.hasOutput else { return .tracked }
        guard let ignored = run(project: project, configurationHome: configurationHome, arguments: ["check-ignore", "-q", "--", artifact.path]) else { return .unknown }
        return ignored.status == 0 ? .ignored : (ignored.status == 1 ? .notIgnored : .unknown)
    }
    private static func hasToolchain() -> Bool {
        if FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools") { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        guard waitForExit(process) else { return false }
        return process.terminationStatus == 0
    }
    /// Shared bounded cancellation path; the process has already started.
    static func waitForExit(_ process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning {
            if Task.isCancelled || Date() >= deadline { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); return false }
            usleep(10_000)
        }
        process.waitUntilExit()
        return true
    }
    private static func run(project: URL, configurationHome: URL?, arguments: [String]) -> (status: Int32, hasOutput: Bool)? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("project-git-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil), let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", project.path] + arguments
        process.environment = ["HOME": (configurationHome ?? FileManager.default.homeDirectoryForCurrentUser).path, "PATH": "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C"]
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        guard waitForExit(process) else { return nil }
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return (process.terminationStatus, size > 0)
    }
}
