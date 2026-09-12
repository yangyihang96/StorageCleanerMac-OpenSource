import Foundation

struct CodexArtifactScanResult: Sendable {
    let intermediateEntries: [DirectoryEntry]
    let runtimeRecordEntries: [DirectoryEntry]
    let installerEntries: [DirectoryEntry]
    let wasLimited: Bool

    static let empty = CodexArtifactScanResult(
        intermediateEntries: [],
        runtimeRecordEntries: [],
        installerEntries: [],
        wasLimited: false
    )
}

struct CodexArtifactScanner {
    struct Configuration: Sendable {
        let codexTemporaryDirectories: [URL]
        let generatedImageDirectories: [URL]
        let workspaceRoots: [URL]
        let systemTemporaryDirectories: [URL]
        let excludedPaths: [String]
        let scanBudget: TimeInterval
        let directoryReadTimeout: TimeInterval
        let directorySizeTimeout: TimeInterval
        let maxTraversalDepth: Int
        let maxVisitedDirectories: Int
        let maxInspectedEntries: Int
        let maxDirectorySizeQueries: Int
        let maxCandidates: Int
        let minimumIntermediateBytes: Int64
        let minimumRuntimeRecordBytes: Int64
        let minimumInstallerBytes: Int64

        static func live(excludedPaths: [String]) -> Configuration {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Configuration(
                codexTemporaryDirectories: [home.appendingPathComponent(".codex/.tmp", isDirectory: true)],
                generatedImageDirectories: [home.appendingPathComponent(".codex/generated_images", isDirectory: true)],
                workspaceRoots: [
                    home.appendingPathComponent("Documents", isDirectory: true),
                    home.appendingPathComponent("Developer", isDirectory: true),
                    home.appendingPathComponent("Projects", isDirectory: true),
                    home.appendingPathComponent("Code", isDirectory: true),
                    home.appendingPathComponent("Workspace", isDirectory: true)
                ],
                systemTemporaryDirectories: [
                    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                    URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                ],
                excludedPaths: excludedPaths,
                scanBudget: 4.5,
                directoryReadTimeout: 0.35,
                directorySizeTimeout: 1.2,
                maxTraversalDepth: 2,
                maxVisitedDirectories: 320,
                maxInspectedEntries: 4_000,
                maxDirectorySizeQueries: 48,
                maxCandidates: 160,
                minimumIntermediateBytes: 1 * 1024 * 1024,
                minimumRuntimeRecordBytes: 256 * 1024,
                minimumInstallerBytes: 1 * 1024 * 1024
            )
        }
    }

    private final class DirectoryReadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<[URL], Error>?

        func set(_ result: Result<[URL], Error>) {
            lock.lock()
            value = result
            lock.unlock()
        }

        func get() -> Result<[URL], Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private enum DirectoryReadOutcome {
        case contents([URL])
        case denied
        case timedOut
    }

    private struct QueueItem {
        let url: URL
        let depth: Int
    }

    private struct ScanState {
        var intermediateEntries = [DirectoryEntry]()
        var runtimeRecordEntries = [DirectoryEntry]()
        var installerEntries = [DirectoryEntry]()
        var seenCandidatePaths = Set<String>()
        var visitedDirectories = 0
        var inspectedEntries = 0
        var directorySizeQueries = 0
        var wasLimited = false
        var stopRequested = false
    }

    private enum EntryDestination {
        case intermediate
        case runtimeRecord
        case installer
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "zip"]
    private static let directoryResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey
    ]

    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func scan(deadline: Date) -> CodexArtifactScanResult {
        let budgetDeadline = Date().addingTimeInterval(configuration.scanBudget)
        let effectiveDeadline = min(deadline, budgetDeadline)
        var state = ScanState()

        scanCodexTemporaryDirectories(state: &state, deadline: effectiveDeadline)
        scanGeneratedImages(state: &state, deadline: effectiveDeadline)
        scanWorkspaceOutputs(state: &state, deadline: effectiveDeadline)
        scanSystemTemporaryOutputs(state: &state, deadline: effectiveDeadline)

        if Date() >= effectiveDeadline {
            state.wasLimited = true
        }

        return CodexArtifactScanResult(
            intermediateEntries: sortedEntries(state.intermediateEntries),
            runtimeRecordEntries: sortedEntries(state.runtimeRecordEntries),
            installerEntries: sortedEntries(state.installerEntries),
            wasLimited: state.wasLimited
        )
    }

    private func scanCodexTemporaryDirectories(state: inout ScanState, deadline: Date) {
        for directory in configuration.codexTemporaryDirectories {
            guard canContinue(state: &state, deadline: deadline) else { return }
            guard isUsableDirectory(directory),
                  !ScanExclusionService.intersectsExcludedTree(
                      directory.path,
                      excludedPaths: configuration.excludedPaths
                  ) else {
                continue
            }
            guard let bytes = directorySizeBytes(directory, state: &state, deadline: deadline),
                  bytes >= configuration.minimumIntermediateBytes else {
                continue
            }

            append(
                DirectoryEntry(
                    name: L10n.text("Codex 运行临时区", "Codex Runtime Temporary Area"),
                    path: PathSafety.normalizedPath(directory.path),
                    sizeBytes: bytes,
                    isDirectory: true
                ),
                to: .intermediate,
                state: &state
            )
        }
    }

    private func scanGeneratedImages(state: inout ScanState, deadline: Date) {
        for directory in configuration.generatedImageDirectories {
            guard canContinue(state: &state, deadline: deadline) else { return }
            guard isUsableDirectory(directory), !isExcluded(directory) else { continue }

            let files = matchingFiles(
                in: directory,
                maximumDepth: 2,
                state: &state,
                deadline: deadline
            ) { url in
                Self.imageExtensions.contains(url.pathExtension.lowercased())
            }
            let bytes = files.reduce(Int64(0)) { $0 + fileSizeBytes($1) }
            guard bytes >= configuration.minimumRuntimeRecordBytes else { continue }

            append(
                DirectoryEntry(
                    name: L10n.text(
                        "Codex 生成图片 · \(files.count) 项",
                        "Codex Generated Images · \(files.count) items"
                    ),
                    path: PathSafety.normalizedPath(directory.path),
                    sizeBytes: bytes,
                    isDirectory: true
                ),
                to: .runtimeRecord,
                state: &state
            )
        }
    }

    private func scanSystemTemporaryOutputs(state: inout ScanState, deadline: Date) {
        for temporaryDirectory in configuration.systemTemporaryDirectories {
            guard isUsableDirectory(temporaryDirectory),
                  !isExcluded(temporaryDirectory),
                  canContinue(state: &state, deadline: deadline) else {
                continue
            }

            switch directoryContents(at: temporaryDirectory, state: &state, deadline: deadline) {
            case .contents(let contents):
                var directoryCandidates = [(url: URL, destination: EntryDestination)]()
                for url in contents.sorted(by: pathSort) {
                    guard canContinue(state: &state, deadline: deadline) else { return }
                    guard let values = try? url.resourceValues(forKeys: Self.directoryResourceKeys),
                          values.isSymbolicLink != true,
                          !isExcluded(url),
                          isRecognizedTemporaryOutput(url, isDirectory: values.isDirectory == true) else {
                        continue
                    }

                    if values.isDirectory == true {
                        directoryCandidates.append((url, temporaryDirectoryDestination(for: url)))
                        continue
                    }

                    let ext = url.pathExtension.lowercased()
                    let bytes = fileSizeBytes(url, values: values)
                    if Self.imageExtensions.contains(ext), bytes >= configuration.minimumRuntimeRecordBytes {
                        append(
                            DirectoryEntry(
                                name: L10n.text("临时验证截图 · \(url.lastPathComponent)", "Temporary Verification Screenshot · \(url.lastPathComponent)"),
                                path: PathSafety.normalizedPath(url.path),
                                sizeBytes: bytes
                            ),
                            to: .runtimeRecord,
                            state: &state
                        )
                    } else if Self.installerExtensions.contains(ext), bytes >= configuration.minimumInstallerBytes {
                        append(
                            DirectoryEntry(
                                name: L10n.text("临时安装包 · \(url.lastPathComponent)", "Temporary Installer · \(url.lastPathComponent)"),
                                path: PathSafety.normalizedPath(url.path),
                                sizeBytes: bytes
                            ),
                            to: .installer,
                            state: &state
                        )
                    }
                }

                let directorySizes = directorySizesBytes(
                    directoryCandidates.map(\.url),
                    state: &state,
                    deadline: deadline
                )
                for candidate in directoryCandidates {
                    guard canContinue(state: &state, deadline: deadline) else { return }
                    let url = candidate.url
                    let normalized = PathSafety.normalizedPath(url.path)
                    let minimumBytes = candidate.destination == .installer
                        ? configuration.minimumInstallerBytes
                        : configuration.minimumRuntimeRecordBytes
                    guard let bytes = directorySizes[normalized],
                          bytes >= minimumBytes else {
                        continue
                    }
                    let isInstaller = candidate.destination == .installer
                    append(
                        DirectoryEntry(
                            name: isInstaller
                                ? L10n.text("临时构建应用 · \(url.lastPathComponent)", "Temporary Built App · \(url.lastPathComponent)")
                                : L10n.text("临时构建 · \(url.lastPathComponent)", "Temporary Build · \(url.lastPathComponent)"),
                            path: normalized,
                            sizeBytes: bytes,
                            isDirectory: true
                        ),
                        to: candidate.destination,
                        state: &state
                    )
                }
            case .denied:
                appendDeniedEntry(for: temporaryDirectory, to: .runtimeRecord, state: &state)
            case .timedOut:
                return
            }
        }
    }

    private func scanWorkspaceOutputs(state: inout ScanState, deadline: Date) {
        var queue = configuration.workspaceRoots.map { QueueItem(url: $0, depth: 0) }
        var queuedPaths = Set(queue.map { PathSafety.normalizedPath($0.url.path) })
        var index = 0

        while index < queue.count {
            guard canContinue(state: &state, deadline: deadline) else { return }
            guard state.visitedDirectories < configuration.maxVisitedDirectories else {
                state.wasLimited = true
                return
            }

            let current = queue[index]
            index += 1
            guard isUsableDirectory(current.url), !isExcluded(current.url) else { continue }
            state.visitedDirectories += 1

            switch directoryContents(at: current.url, state: &state, deadline: deadline) {
            case .contents(let contents):
                for child in contents.sorted(by: pathSort) {
                    guard canContinue(state: &state, deadline: deadline) else { return }
                    guard state.inspectedEntries < configuration.maxInspectedEntries else {
                        state.wasLimited = true
                        return
                    }
                    state.inspectedEntries += 1

                    guard !isExcluded(child),
                          let values = try? child.resourceValues(forKeys: Self.directoryResourceKeys),
                          values.isSymbolicLink != true,
                          values.isDirectory == true else {
                        continue
                    }

                    let name = child.lastPathComponent.lowercased()
                    switch name {
                    case ".playwright-mcp", ".playwright-cli":
                        scanPlaywrightDirectory(child, state: &state, deadline: deadline)
                    case "function-check", "screenshots":
                        guard isRecognizedScreenshotDirectory(child) else { continue }
                        scanScreenshotDirectory(child, state: &state, deadline: deadline)
                    case "release":
                        scanInstallerDirectory(child, kind: .release, state: &state, deadline: deadline)
                        scanNamedScreenshotChildren(of: child, state: &state, deadline: deadline)
                    case "dist":
                        scanInstallerDirectory(child, kind: .dist, state: &state, deadline: deadline)
                    default:
                        guard current.depth < configuration.maxTraversalDepth,
                              !shouldSkipTraversal(child) else {
                            continue
                        }
                        let normalized = PathSafety.normalizedPath(child.path)
                        if queuedPaths.insert(normalized).inserted {
                            queue.append(QueueItem(url: child, depth: current.depth + 1))
                        }
                    }
                }
            case .denied:
                appendDeniedEntry(for: current.url, to: .runtimeRecord, state: &state)
            case .timedOut:
                return
            }
        }
    }

    private func scanPlaywrightDirectory(_ directory: URL, state: inout ScanState, deadline: Date) {
        guard canContinue(state: &state, deadline: deadline) else { return }

        switch directoryContents(at: directory, state: &state, deadline: deadline) {
        case .contents(let contents):
            var runtimeFiles = [URL]()
            var installerFiles = [URL]()

            for file in contents.sorted(by: pathSort) {
                guard canContinue(state: &state, deadline: deadline) else { return }
                guard state.inspectedEntries < configuration.maxInspectedEntries else {
                    state.wasLimited = true
                    return
                }
                state.inspectedEntries += 1

                guard !isExcluded(file),
                      let values = try? file.resourceValues(forKeys: Self.directoryResourceKeys),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true else {
                    continue
                }

                if isPlaywrightRuntimeRecord(file) {
                    runtimeFiles.append(file)
                } else if isPlaywrightGeneratedInstaller(file, in: directory) {
                    installerFiles.append(file)
                }
            }

            let runtimeBytes = runtimeFiles.reduce(Int64(0)) { $0 + fileSizeBytes($1) }
            if runtimeBytes >= configuration.minimumRuntimeRecordBytes {
                append(
                    DirectoryEntry(
                        name: L10n.text(
                            "自动化截图与运行记录 · \(runtimeFiles.count) 项",
                            "Automation Screenshots & Runtime Records · \(runtimeFiles.count) items"
                        ),
                        path: PathSafety.normalizedPath(directory.path),
                        sizeBytes: runtimeBytes,
                        isDirectory: true
                    ),
                    to: .runtimeRecord,
                    state: &state
                )
            }

            let installerBytes = installerFiles.reduce(Int64(0)) { $0 + fileSizeBytes($1) }
            if installerBytes >= configuration.minimumInstallerBytes, let representative = installerFiles.first {
                append(
                    DirectoryEntry(
                        name: L10n.text(
                            "自动化目录安装包 · \(installerFiles.count) 项",
                            "Automation Folder Installers · \(installerFiles.count) items"
                        ),
                        path: PathSafety.normalizedPath(representative.path),
                        sizeBytes: installerBytes
                    ),
                    to: .installer,
                    state: &state
                )
            }
        case .denied:
            appendDeniedEntry(for: directory, to: .runtimeRecord, state: &state)
        case .timedOut:
            return
        }
    }

    private enum InstallerDirectoryKind {
        case release
        case dist
    }

    private func scanInstallerDirectory(
        _ directory: URL,
        kind: InstallerDirectoryKind,
        state: inout ScanState,
        deadline: Date
    ) {
        guard canContinue(state: &state, deadline: deadline) else { return }

        switch directoryContents(at: directory, state: &state, deadline: deadline) {
        case .contents(let contents):
            var count = 0
            var bytes: Int64 = 0
            var appBundles = [URL]()

            for item in contents.sorted(by: pathSort) {
                guard canContinue(state: &state, deadline: deadline) else { return }
                guard state.inspectedEntries < configuration.maxInspectedEntries else {
                    state.wasLimited = true
                    return
                }
                state.inspectedEntries += 1

                guard !isExcluded(item),
                      let values = try? item.resourceValues(forKeys: Self.directoryResourceKeys),
                      values.isSymbolicLink != true else {
                    continue
                }

                let ext = item.pathExtension.lowercased()
                if values.isRegularFile == true, Self.installerExtensions.contains(ext) {
                    count += 1
                    bytes += fileSizeBytes(item, values: values)
                } else if values.isDirectory == true, ext == "app" {
                    count += 1
                    appBundles.append(item)
                }
            }

            if !appBundles.isEmpty {
                switch kind {
                case .dist:
                    bytes = directorySizeBytes(directory, state: &state, deadline: deadline) ?? bytes
                case .release:
                    let appSizes = directorySizesBytes(appBundles, state: &state, deadline: deadline)
                    bytes += appSizes.values.reduce(0, +)
                }
            }

            guard count > 0, bytes >= configuration.minimumInstallerBytes else { return }
            let project = projectName(for: directory)
            let name: String
            switch kind {
            case .release:
                name = L10n.text("\(project) · \(count) 个发布安装包", "\(project) · \(count) release packages")
            case .dist:
                name = L10n.text("\(project) · \(count) 个构建应用", "\(project) · \(count) built apps")
            }
            append(
                DirectoryEntry(
                    name: name,
                    path: PathSafety.normalizedPath(directory.path),
                    sizeBytes: bytes,
                    isDirectory: true
                ),
                to: .installer,
                state: &state
            )
        case .denied:
            appendDeniedEntry(for: directory, to: .installer, state: &state)
        case .timedOut:
            return
        }
    }

    private func scanNamedScreenshotChildren(of directory: URL, state: inout ScanState, deadline: Date) {
        guard canContinue(state: &state, deadline: deadline) else { return }
        guard case .contents(let contents) = directoryContents(at: directory, state: &state, deadline: deadline) else {
            return
        }

        for child in contents where ["function-check", "screenshots"].contains(child.lastPathComponent.lowercased()) {
            guard isUsableDirectory(child), !isExcluded(child) else { continue }
            scanScreenshotDirectory(child, state: &state, deadline: deadline)
        }
    }

    private func scanScreenshotDirectory(_ directory: URL, state: inout ScanState, deadline: Date) {
        let files = matchingFiles(
            in: directory,
            maximumDepth: 2,
            state: &state,
            deadline: deadline
        ) { url in
            Self.imageExtensions.contains(url.pathExtension.lowercased())
        }
        let bytes = files.reduce(Int64(0)) { $0 + fileSizeBytes($1) }
        guard bytes >= configuration.minimumRuntimeRecordBytes else { return }

        let project = projectName(for: directory)
        append(
            DirectoryEntry(
                name: L10n.text(
                    "\(project) · \(files.count) 张验证截图",
                    "\(project) · \(files.count) verification screenshots"
                ),
                path: PathSafety.normalizedPath(directory.path),
                sizeBytes: bytes,
                isDirectory: true
            ),
            to: .runtimeRecord,
            state: &state
        )
    }

    private func matchingFiles(
        in root: URL,
        maximumDepth: Int,
        state: inout ScanState,
        deadline: Date,
        predicate: (URL) -> Bool
    ) -> [URL] {
        var queue = [QueueItem(url: root, depth: 0)]
        var index = 0
        var files = [URL]()

        while index < queue.count {
            guard canContinue(state: &state, deadline: deadline) else { break }
            let current = queue[index]
            index += 1

            switch directoryContents(at: current.url, state: &state, deadline: deadline) {
            case .contents(let contents):
                for child in contents.sorted(by: pathSort) {
                    guard canContinue(state: &state, deadline: deadline) else { return files }
                    guard state.inspectedEntries < configuration.maxInspectedEntries else {
                        state.wasLimited = true
                        return files
                    }
                    state.inspectedEntries += 1

                    guard !isExcluded(child),
                          let values = try? child.resourceValues(forKeys: Self.directoryResourceKeys),
                          values.isSymbolicLink != true else {
                        continue
                    }
                    if values.isDirectory == true, current.depth < maximumDepth {
                        queue.append(QueueItem(url: child, depth: current.depth + 1))
                    } else if values.isRegularFile == true, predicate(child) {
                        files.append(child)
                    }
                }
            case .denied:
                appendDeniedEntry(for: current.url, to: .runtimeRecord, state: &state)
            case .timedOut:
                return files
            }
        }

        return files
    }

    private func directoryContents(at url: URL, state: inout ScanState, deadline: Date) -> DirectoryReadOutcome {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            state.wasLimited = true
            state.stopRequested = true
            return .timedOut
        }

        let box = DirectoryReadBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Array(Self.directoryResourceKeys),
                    options: [.skipsSubdirectoryDescendants]
                )
                box.set(.success(urls))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        let timeout = min(configuration.directoryReadTimeout, remaining)
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            state.wasLimited = true
            state.stopRequested = true
            return .timedOut
        }

        switch box.get() {
        case .success(let urls):
            return .contents(urls)
        case .failure:
            return .denied
        case nil:
            state.wasLimited = true
            state.stopRequested = true
            return .timedOut
        }
    }

    private func directorySizeBytes(_ url: URL, state: inout ScanState, deadline: Date) -> Int64? {
        guard state.directorySizeQueries < configuration.maxDirectorySizeQueries else {
            state.wasLimited = true
            return nil
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.1 else {
            state.wasLimited = true
            state.stopRequested = true
            return nil
        }

        state.directorySizeQueries += 1
        let timeout = min(configuration.directorySizeTimeout, max(0.05, remaining - 0.05))
        let output: String
        do {
            output = try Shell.capture("/usr/bin/du", ["-sk", url.path], timeout: timeout)
        } catch {
            state.wasLimited = true
            return nil
        }
        guard let kilobytes = Int64(output.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? "") else {
            state.wasLimited = true
            return nil
        }
        return kilobytes * 1024
    }

    private func directorySizesBytes(
        _ urls: [URL],
        state: inout ScanState,
        deadline: Date
    ) -> [String: Int64] {
        guard !urls.isEmpty else { return [:] }
        var sizes = [String: Int64]()
        for url in urls {
            guard canContinue(state: &state, deadline: deadline) else { break }
            guard state.directorySizeQueries < configuration.maxDirectorySizeQueries else {
                state.wasLimited = true
                break
            }
            if let bytes = directorySizeBytes(url, state: &state, deadline: deadline) {
                sizes[PathSafety.normalizedPath(url.path)] = bytes
            }
        }
        return sizes
    }

    private func fileSizeBytes(_ url: URL, values: URLResourceValues? = nil) -> Int64 {
        let resolvedValues = values ?? (try? url.resourceValues(forKeys: Self.directoryResourceKeys))
        return Int64(resolvedValues?.totalFileAllocatedSize ?? resolvedValues?.fileSize ?? 0)
    }

    private func isPlaywrightRuntimeRecord(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if Self.imageExtensions.contains(ext) {
            return matchesGeneratedRecordName(
                stem,
                tokens: ["screen", "screenshot", "snapshot", "page", "exec", "browser", "capture"]
            )
        }
        if ext == "yml" || ext == "yaml" {
            return matchesGeneratedRecordName(stem, tokens: ["page", "snapshot"])
        }
        if ext == "log" {
            return matchesGeneratedRecordName(stem, tokens: ["console", "network"])
        }
        if ext == "zip" {
            return matchesGeneratedRecordName(stem, tokens: ["trace"])
        }
        return false
    }

    private func matchesGeneratedRecordName(_ stem: String, tokens: [String]) -> Bool {
        tokens.contains { token in
            stem == token || stem.hasPrefix("\(token)-") || stem.hasPrefix("\(token)_")
        }
    }

    private func isRecognizedScreenshotDirectory(_ directory: URL) -> Bool {
        let parent = directory.deletingLastPathComponent()
        if parent.lastPathComponent.lowercased() == "release" {
            return true
        }
        return hasDevelopmentMarker(at: parent)
    }

    private func hasDevelopmentMarker(at directory: URL) -> Bool {
        [".git", "Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "go.mod"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    private func isPlaywrightGeneratedInstaller(_ url: URL, in directory: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard Self.installerExtensions.contains(ext) else { return false }
        // DMG/PKG/XIP are unambiguous installer formats. ZIP is intentionally
        // stricter because automation folders often also contain user archives.
        if ext != "zip" {
            return true
        }
        let fileKey = comparisonKey(url.deletingPathExtension().lastPathComponent)
        let projectKey = comparisonKey(directory.deletingLastPathComponent().lastPathComponent)
        if fileKey.contains("storagecleaner") || fileKey.contains("codex") {
            return true
        }
        if projectKey.count >= 3, fileKey.contains(projectKey) {
            return true
        }
        return ["build", "dist", "release", "installer", "package", "artifact"].contains { token in
            fileKey.hasPrefix(token)
        }
    }

    private func isRecognizedTemporaryOutput(_ url: URL, isDirectory: Bool) -> Bool {
        let name = url.lastPathComponent.lowercased().replacingOccurrences(of: "_", with: "-")
        if isStorageCleanerTemporaryName(name) {
            return true
        }
        guard name.hasPrefix("codex-") else { return false }
        if !isDirectory {
            let ext = url.pathExtension.lowercased()
            return Self.imageExtensions.contains(ext) || Self.installerExtensions.contains(ext)
        }
        if url.pathExtension.lowercased() == "app" {
            return true
        }
        return ["build", "dist", "release", "package", "installer", "artifact", "output", "screenshot", "image"].contains {
            name.contains($0)
        }
    }

    private func temporaryDirectoryDestination(for url: URL) -> EntryDestination {
        if url.pathExtension.lowercased() == "app" {
            return .installer
        }
        let name = url.lastPathComponent.lowercased().replacingOccurrences(of: "_", with: "-")
        if ["build", "dist", "release", "package", "installer", "artifact", "output"].contains(where: name.contains) {
            return .installer
        }
        return .runtimeRecord
    }

    private func comparisonKey(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func isStorageCleanerTemporaryName(_ name: String) -> Bool {
        let normalized = name.lowercased().replacingOccurrences(of: "_", with: "-")
        return normalized.contains("storage-cleaner") || normalized.contains("storagecleanermac")
    }

    private func isUsableDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func shouldSkipTraversal(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix(".") {
            return true
        }
        if url.pathExtension.lowercased() == "app" {
            return true
        }
        return [
            "library", "applications", "node_modules", "pods", ".git", ".svn",
            ".build", ".swiftpm", ".codebase-memory", "deriveddata", "caches"
        ].contains(name)
    }

    private func isExcluded(_ url: URL) -> Bool {
        ScanExclusionService.isExcluded(url.path, excludedPaths: configuration.excludedPaths)
    }

    private func canContinue(state: inout ScanState, deadline: Date) -> Bool {
        if state.stopRequested {
            return false
        }
        if Date() >= deadline {
            state.wasLimited = true
            state.stopRequested = true
            return false
        }
        if state.seenCandidatePaths.count >= configuration.maxCandidates {
            state.wasLimited = true
            state.stopRequested = true
            return false
        }
        return true
    }

    private func append(
        _ entry: DirectoryEntry,
        to destination: EntryDestination,
        state: inout ScanState
    ) {
        guard state.seenCandidatePaths.count < configuration.maxCandidates else {
            state.wasLimited = true
            state.stopRequested = true
            return
        }
        let normalized = PathSafety.normalizedPath(entry.path)
        guard state.seenCandidatePaths.insert(normalized).inserted else { return }
        switch destination {
        case .intermediate:
            state.intermediateEntries.append(entry)
        case .runtimeRecord:
            state.runtimeRecordEntries.append(entry)
        case .installer:
            state.installerEntries.append(entry)
        }
    }

    private func appendDeniedEntry(
        for url: URL,
        to destination: EntryDestination,
        state: inout ScanState
    ) {
        append(
            DirectoryEntry(
                name: url.lastPathComponent,
                path: PathSafety.normalizedPath(url.path),
                sizeBytes: 0,
                denied: true,
                isDirectory: true
            ),
            to: destination,
            state: &state
        )
    }

    private func projectName(for directory: URL) -> String {
        let name = directory.lastPathComponent.lowercased()
        if name == "function-check" {
            let parent = directory.deletingLastPathComponent()
            if parent.lastPathComponent.lowercased() == "release" {
                return parent.deletingLastPathComponent().lastPathComponent
            }
        }
        return directory.deletingLastPathComponent().lastPathComponent
    }

    private func sortedEntries(_ entries: [DirectoryEntry]) -> [DirectoryEntry] {
        entries.sorted { lhs, rhs in
            if lhs.sizeBytes == rhs.sizeBytes {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }
    }

    private func pathSort(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}
