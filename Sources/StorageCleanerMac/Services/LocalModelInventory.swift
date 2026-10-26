import Darwin
import Foundation

/// D86：本地 AI 模型只读盘点（Ollama、LM Studio）。只读取目录、清单 JSON
/// 与文件元数据，不打开模型文件内容、不跟随符号链接、不删除任何东西。
/// 删除需要后续批次单独设计显式计划。
enum LocalModelSource: String, CaseIterable, Sendable {
    case ollama
    case lmStudio

    var title: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }
}

struct LocalModelEntry: Identifiable, Equatable, Sendable {
    let id: String
    let source: LocalModelSource
    let name: String
    /// 例如 “GGUF · Q4_K_M” 或 “Safetensors”；未知时为 nil。
    let format: String?
    /// 这个模型引用的全部文件的本地占用（共享文件按完整大小算进每个模型）。
    let bytes: Int64
    /// 只属于这个模型的部分。
    let exclusiveBytes: Int64
    /// 与其他模型共用的部分；合计中只算一次。
    let sharedBytes: Int64
    /// 共用文件的其他模型名。
    let sharedWith: [String]
    let fileCount: Int
    /// 清单引用了、但磁盘上找不到的文件数。
    let missingFileCount: Int
    /// 清单文件或模型文件夹的位置。
    let location: String
}

struct LocalModelRootStatus: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case absent
        case scanned
        /// 位置本身是符号链接：不跟随，未读取。
        case symbolicLink(destination: String?)
        /// 家目录以下的某一层上级（例如 ~/.ollama）是符号链接：不跟随，未读取。
        case linkedAncestor(path: String, destination: String?)
        /// 与另一个已读取的位置是同一个文件夹，不重复计算。
        case sameAs(String)
        case unreadable
    }

    let source: LocalModelSource
    let path: String
    let state: State
    var id: String { source.rawValue + ":" + path }
}

struct LocalModelInventory: Equatable, Sendable {
    let roots: [LocalModelRootStatus]
    let models: [LocalModelEntry]
    /// 无法解析的 Ollama 清单（相对 manifests 的路径）；不计入任何模型。
    let unknownManifests: [String]
    /// 没有被任何清单引用的 Ollama 文件。
    let unreferencedBlobCount: Int
    let unreferencedBlobBytes: Int64
    /// 遇到并跳过的符号链接（不跟随，也不计入大小）。
    let skippedSymbolicLinks: [String]
    /// 达到条目上限或被取消：之后的内容都没有读。
    let stoppedEarly: Bool
    /// 超过层级上限、没有进入的文件夹；只跳过这些子树，其余照常盘点。
    let skippedDeepFolders: [String]
    /// 列不出内容的文件夹（权限不足等）。
    let unreadableFolders: [String]

    /// 任一原因导致结果不完整。
    var isIncomplete: Bool { stoppedEarly || !skippedDeepFolders.isEmpty || !unreadableFolders.isEmpty }

    /// 所有模型引用文件的本地占用合计，共享文件只计一次。
    let totalBytes: Int64

    static let empty = LocalModelInventory(
        roots: [], models: [], unknownManifests: [], unreferencedBlobCount: 0,
        unreferencedBlobBytes: 0, skippedSymbolicLinks: [], stoppedEarly: false,
        skippedDeepFolders: [], unreadableFolders: [], totalBytes: 0
    )

    var hasAnyRoot: Bool { roots.contains { $0.state != .absent } }
}

struct LocalModelInventoryScanner: Sendable {
    let homePath: String
    /// 单次盘点最多处理的文件/清单数，防止异常目录拖住界面。
    var entryLimit = 20_000
    /// 单个清单 / 配置 JSON 最多读取的字节数。
    var jsonByteLimit = 1 << 20
    var isCancelled: @Sendable () -> Bool = { Task.isCancelled }

    init(homePath: String = PathSafety.homePath) {
        self.homePath = homePath
    }

    /// 默认位置：Ollama 为 ~/.ollama/models；LM Studio 依次为
    /// ~/.lmstudio/models 与 ~/.cache/lm-studio/models（以实际存在为准）。
    var ollamaRoot: String { homePath + "/.ollama/models" }
    var lmStudioRoots: [String] { [homePath + "/.lmstudio/models", homePath + "/.cache/lm-studio/models"] }

    func scan() -> LocalModelInventory {
        var context = Context(limit: entryLimit, isCancelled: isCancelled)
        var roots = [LocalModelRootStatus]()
        var models = [LocalModelEntry]()
        var unknownManifests = [String]()
        var unreferenced = (count: 0, bytes: Int64(0))
        var countedFiles = [FileKey: Int64]()

        let ollamaState = rootState(ollamaRoot)
        roots.append(LocalModelRootStatus(source: .ollama, path: ollamaRoot, state: ollamaState.state))
        if ollamaState.state == .scanned {
            let result = scanOllama(root: ollamaRoot, context: &context)
            models += result.models
            unknownManifests = result.unknownManifests
            unreferenced = (result.unreferencedCount, result.unreferencedBytes)
            for (key, bytes) in result.files { countedFiles[key] = bytes }
        }

        var seenRootIdentities = [FileKey: String]()
        if let identity = ollamaState.identity { seenRootIdentities[identity] = ollamaRoot }
        for root in lmStudioRoots {
            let state = rootState(root)
            if state.state == .scanned, let identity = state.identity {
                if let earlier = seenRootIdentities[identity] {
                    roots.append(LocalModelRootStatus(source: .lmStudio, path: root, state: .sameAs(earlier)))
                    continue
                }
                seenRootIdentities[identity] = root
            }
            roots.append(LocalModelRootStatus(source: .lmStudio, path: root, state: state.state))
            guard state.state == .scanned, !context.isStopped else { continue }
            let result = scanLMStudio(root: root, context: &context)
            models += result.models
            for (key, bytes) in result.files { countedFiles[key] = bytes }
        }

        let total = countedFiles.values.reduce(Int64(0)) { Self.add($0, $1) }
        return LocalModelInventory(
            roots: roots,
            models: models.sorted {
                $0.bytes == $1.bytes ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.bytes > $1.bytes
            },
            unknownManifests: unknownManifests.sorted(),
            unreferencedBlobCount: unreferenced.count,
            unreferencedBlobBytes: unreferenced.bytes,
            skippedSymbolicLinks: context.skippedSymbolicLinks.sorted(),
            stoppedEarly: context.isStopped,
            skippedDeepFolders: context.skippedDeepFolders.sorted(),
            unreadableFolders: context.unreadableFolders.sorted(),
            totalBytes: total
        )
    }

    // MARK: - Ollama

    private struct OllamaResult {
        var models: [LocalModelEntry] = []
        var unknownManifests: [String] = []
        var unreferencedCount = 0
        var unreferencedBytes: Int64 = 0
        var files: [FileKey: Int64] = [:]
    }

    private struct ParsedManifest {
        let relativePath: String
        let name: String
        let configDigest: String?
        let layers: [(mediaType: String, digest: String)]
    }

    private func scanOllama(root: String, context: inout Context) -> OllamaResult {
        var result = OllamaResult()
        let manifestsRoot = root + "/manifests"
        let blobsRoot = root + "/blobs"

        // 1. 盘点 blobs：只取元数据，不跟随符号链接。
        var blobs = [String: (key: FileKey, bytes: Int64)]()
        for path in [manifestsRoot, blobsRoot] {
            if case .symbolicLink = Self.directoryState(path).state { context.skippedSymbolicLinks.append(path) }
        }
        let blobsState = Self.directoryState(blobsRoot).state
        if blobsState == .unreadable { context.unreadableFolders.append(blobsRoot) }
        if blobsState == .scanned {
            for name in context.list(blobsRoot) {
                guard context.consume() else { break }
                let path = blobsRoot + "/" + name
                guard let status = Self.lstatus(path) else { continue }
                if Self.isSymbolicLink(status) {
                    context.skippedSymbolicLinks.append(path)
                    continue
                }
                guard Self.isRegularFile(status), let digest = Self.digest(fromBlobName: name) else { continue }
                blobs[digest] = (FileKey(status), Self.allocatedBytes(status))
            }
        }

        // 2. 解析 manifests/<host>/<namespace>/<model>/<tag>。
        var manifests = [ParsedManifest]()
        let manifestsState = Self.directoryState(manifestsRoot).state
        if manifestsState == .unreadable { context.unreadableFolders.append(manifestsRoot) }
        if manifestsState == .scanned, !context.isStopped {
            walkFiles(under: manifestsRoot, maxDepth: 6, context: &context) { path, relative in
                if let manifest = parseOllamaManifest(at: path, relativePath: relative) {
                    manifests.append(manifest)
                } else {
                    result.unknownManifests.append(relative)
                }
            }
        }

        // 3. 每个 blob 被多少个模型引用。
        var referencingModels = [String: Set<String>]()
        for manifest in manifests {
            for digest in Set(manifest.layers.map(\.digest) + [manifest.configDigest].compactMap { $0 }) {
                referencingModels[digest, default: []].insert(manifest.relativePath)
            }
        }
        let namesByManifest = Dictionary(manifests.map { ($0.relativePath, $0.name) }, uniquingKeysWith: { first, _ in first })

        for manifest in manifests {
            let digests = Set(manifest.layers.map(\.digest) + [manifest.configDigest].compactMap { $0 })
            var bytes: Int64 = 0, exclusive: Int64 = 0, shared: Int64 = 0
            var fileCount = 0, missing = 0
            var sharedWith = Set<String>()
            for digest in digests {
                guard let blob = blobs[digest] else {
                    missing += 1
                    continue
                }
                fileCount += 1
                bytes = Self.add(bytes, blob.bytes)
                result.files[blob.key] = blob.bytes
                let others = (referencingModels[digest] ?? []).subtracting([manifest.relativePath])
                if others.isEmpty {
                    exclusive = Self.add(exclusive, blob.bytes)
                } else {
                    shared = Self.add(shared, blob.bytes)
                    sharedWith.formUnion(others.compactMap { namesByManifest[$0] })
                }
            }
            result.models.append(LocalModelEntry(
                id: "ollama:" + manifest.relativePath,
                source: .ollama,
                name: manifest.name,
                format: ollamaFormat(manifest: manifest, blobsRoot: blobsRoot, blobs: blobs),
                bytes: bytes,
                exclusiveBytes: exclusive,
                sharedBytes: shared,
                sharedWith: sharedWith.sorted(),
                fileCount: fileCount,
                missingFileCount: missing,
                location: manifestsRoot + "/" + manifest.relativePath
            ))
        }

        let referenced = Set(referencingModels.keys)
        for (digest, blob) in blobs where !referenced.contains(digest) {
            result.unreferencedCount += 1
            result.unreferencedBytes = Self.add(result.unreferencedBytes, blob.bytes)
        }
        return result
    }

    private func parseOllamaManifest(at path: String, relativePath: String) -> ParsedManifest? {
        guard let object = readJSONObject(at: path),
              let layers = object["layers"] as? [[String: Any]], !layers.isEmpty else { return nil }
        let parsedLayers = layers.compactMap { layer -> (String, String)? in
            guard let digest = layer["digest"] as? String, Self.isValidDigest(digest) else { return nil }
            return ((layer["mediaType"] as? String) ?? "", digest)
        }
        guard parsedLayers.count == layers.count else { return nil }
        let configDigest = ((object["config"] as? [String: Any])?["digest"] as? String)
            .flatMap { Self.isValidDigest($0) ? $0 : nil }
        return ParsedManifest(
            relativePath: relativePath,
            name: Self.ollamaModelName(relativePath: relativePath),
            configDigest: configDigest,
            layers: parsedLayers.map { (mediaType: $0.0, digest: $0.1) }
        )
    }

    /// registry.ollama.ai/library/llama3/8b → llama3:8b；其他命名空间保留前缀。
    static func ollamaModelName(relativePath: String) -> String {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return relativePath }
        let tag = parts[parts.count - 1]
        let model = parts[parts.count - 2]
        let prefix = parts.dropLast(2)
        var name = model + ":" + tag
        if prefix.count == 2, prefix.first == "registry.ollama.ai", prefix.last == "library" {
            return name
        }
        if prefix.first == "registry.ollama.ai" {
            name = prefix.dropFirst().joined(separator: "/") + "/" + name
        } else if !prefix.isEmpty {
            name = prefix.joined(separator: "/") + "/" + name
        }
        return name
    }

    private func ollamaFormat(
        manifest: ParsedManifest,
        blobsRoot: String,
        blobs: [String: (key: FileKey, bytes: Int64)]
    ) -> String? {
        var parts = [String]()
        if let digest = manifest.configDigest, blobs[digest] != nil,
           let config = readJSONObject(at: blobsRoot + "/" + Self.blobName(fromDigest: digest)) {
            if let format = (config["model_format"] as? String)?.nonEmpty { parts.append(format.uppercased()) }
            if let type = (config["file_type"] as? String)?.nonEmpty { parts.append(type) }
        }
        if parts.isEmpty, manifest.layers.contains(where: { $0.mediaType == "application/vnd.ollama.image.model" }) {
            parts.append(L10n.text("Ollama 模型", "Ollama model"))
        }
        if manifest.layers.contains(where: { $0.mediaType == "application/vnd.ollama.image.adapter" }) {
            parts.append(L10n.text("含适配器", "With adapter"))
        }
        if manifest.layers.contains(where: { $0.mediaType == "application/vnd.ollama.image.projector" }) {
            parts.append(L10n.text("含视觉投影", "With projector"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - LM Studio

    private struct LMStudioResult {
        var models: [LocalModelEntry] = []
        var files: [FileKey: Int64] = [:]
    }

    /// 模型 = models/<发布者>/<模型> 文件夹；里面的模型文件按扩展名识别格式。
    private func scanLMStudio(root: String, context: inout Context) -> LMStudioResult {
        var result = LMStudioResult()
        let publishers = context.list(root).filter { !$0.hasPrefix(".") }.sorted()
        for publisher in publishers {
            // 每个发布者文件夹也计一项：取消或到上限后不再 lstat、列目录。
            guard context.consume() else { break }
            let publisherPath = root + "/" + publisher
            guard let status = Self.lstatus(publisherPath) else { continue }
            if Self.isSymbolicLink(status) {
                context.skippedSymbolicLinks.append(publisherPath)
                continue
            }
            guard Self.isDirectory(status) else { continue }
            let modelDirectories = context.list(publisherPath).filter { !$0.hasPrefix(".") }.sorted()
            for model in modelDirectories {
                guard context.consume() else { break }
                let modelPath = publisherPath + "/" + model
                guard let modelStatus = Self.lstatus(modelPath) else { continue }
                if Self.isSymbolicLink(modelStatus) {
                    context.skippedSymbolicLinks.append(modelPath)
                    continue
                }
                guard Self.isDirectory(modelStatus) else { continue }
                var files = [FileKey: Int64]()
                var formats = Set<String>()
                walkFiles(under: modelPath, maxDepth: 4, context: &context) { path, _ in
                    guard let fileStatus = Self.lstatus(path) else { return }
                    let key = FileKey(fileStatus)
                    files[key] = Self.allocatedBytes(fileStatus)
                    if let format = Self.lmStudioFormat(fileName: (path as NSString).lastPathComponent) {
                        formats.insert(format)
                    }
                }
                guard !formats.isEmpty else { continue }
                let bytes = files.values.reduce(Int64(0)) { Self.add($0, $1) }
                for (key, value) in files { result.files[key] = value }
                result.models.append(LocalModelEntry(
                    id: "lmstudio:" + modelPath,
                    source: .lmStudio,
                    name: publisher + "/" + model,
                    format: formats.sorted().joined(separator: " · "),
                    bytes: bytes,
                    exclusiveBytes: bytes,
                    sharedBytes: 0,
                    sharedWith: [],
                    fileCount: files.count,
                    missingFileCount: 0,
                    location: modelPath
                ))
            }
        }
        return result
    }

    static func lmStudioFormat(fileName: String) -> String? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "gguf": "GGUF"
        case "safetensors": "Safetensors"
        case "mlx", "npz": "MLX"
        case "bin": fileName.lowercased().contains("model") ? "PyTorch bin" : nil
        default: nil
        }
    }

    // MARK: - Walking

    /// 只走真实文件夹，不跟随符号链接；隐藏文件跳过。
    private func walkFiles(
        under root: String,
        maxDepth: Int,
        context: inout Context,
        visit: (_ path: String, _ relative: String) -> Void
    ) {
        var stack: [(path: String, relative: String, depth: Int)] = [(root, "", 0)]
        while let current = stack.popLast() {
            guard context.consume() else { return }
            let children = context.list(current.path).filter { !$0.hasPrefix(".") }.sorted()
            for child in children {
                let path = current.path + "/" + child
                let relative = current.relative.isEmpty ? child : current.relative + "/" + child
                guard let status = Self.lstatus(path) else { continue }
                if Self.isSymbolicLink(status) {
                    context.skippedSymbolicLinks.append(path)
                } else if Self.isDirectory(status) {
                    if current.depth + 1 < maxDepth {
                        stack.append((path, relative, current.depth + 1))
                    } else {
                        // 只跳过这一棵过深的子树并单独说明，不停止整个盘点。
                        context.skippedDeepFolders.append(path)
                    }
                } else if Self.isRegularFile(status) {
                    guard context.consume() else { return }
                    visit(path, relative)
                }
            }
        }
    }

    private func readJSONObject(at path: String) -> [String: Any]? {
        guard let data = Self.readRegularFile(at: path, byteLimit: jsonByteLimit) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 只读一个普通文件，最多 `byteLimit` 字节。先打开再检查同一个文件描述符，
    /// 避免检查与打开之间被换成链接或 FIFO：`O_NOFOLLOW` 拒绝符号链接，
    /// `O_NONBLOCK` 让 FIFO / 设备不会卡住打开，`fstat` 确认是普通文件且不超限。
    static func readRegularFile(at path: String, byteLimit: Int) -> Data? {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, isRegularFile(status),
              status.st_size >= 0, status.st_size <= Int64(byteLimit) else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= byteLimit {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        // 读的过程中文件变长：超过上限就放弃，不截断解析。
        return data.count <= byteLimit ? data : nil
    }

    // MARK: - Helpers

    struct FileKey: Hashable, Sendable {
        let device: Int64
        let inode: UInt64
        init(_ status: stat) {
            device = Int64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    private struct Context {
        let limit: Int
        let isCancelled: @Sendable () -> Bool
        var used = 0
        /// 达到条目上限或被取消；只由 `consume()` 设置。
        private(set) var isStopped = false
        var skippedSymbolicLinks = [String]()
        var skippedDeepFolders = [String]()
        var unreadableFolders = [String]()

        init(limit: Int, isCancelled: @escaping @Sendable () -> Bool) {
            self.limit = limit
            self.isCancelled = isCancelled
        }

        mutating func consume() -> Bool {
            guard !isStopped else { return false }
            if used >= limit || isCancelled() {
                isStopped = true
                return false
            }
            used += 1
            return true
        }

        /// 列出文件夹内容；已停止时不再列，列不出时记下（结果不完整）。
        mutating func list(_ path: String) -> [String] {
            guard !isStopped else { return [] }
            do {
                return try FileManager.default.contentsOfDirectory(atPath: path)
            } catch {
                unreadableFolders.append(path)
                return []
            }
        }
    }

    /// 默认位置的状态：家目录以下的每一层（例如 ~/.ollama 与 ~/.ollama/models）
    /// 都不能是符号链接；全部是真实文件夹时再用 realpath 前缀比对确认没有绕出去。
    /// 家目录本身及其上级（例如临时目录所在的 /var → /private/var）不在检查范围。
    /// D116 G11 的 iOS 备份盘点用同一个检查（不会返回 `.sameAs`）。
    func rootState(_ path: String) -> (state: LocalModelRootStatus.State, identity: FileKey?) {
        let home = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        guard path.hasPrefix(home + "/") else { return Self.directoryState(path) }
        let components = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        var current = home
        for (index, component) in components.enumerated() {
            current += "/" + component
            guard let status = Self.lstatus(current) else { return (.absent, nil) }
            guard Self.isSymbolicLink(status) else { continue }
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current)
            return index == components.count - 1
                ? (.symbolicLink(destination: destination), nil)
                : (.linkedAncestor(path: current, destination: destination), nil)
        }
        let state = Self.directoryState(path)
        guard state.state == .scanned else { return state }
        guard let resolvedHome = Self.realPath(home), let resolvedRoot = Self.realPath(path),
              resolvedRoot == resolvedHome + "/" + components.joined(separator: "/") else {
            return (.linkedAncestor(path: path, destination: Self.realPath(path)), nil)
        }
        return state
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 单个文件夹的状态：不存在、是符号链接（不跟随）、读不了或可读取。
    private static func directoryState(_ path: String) -> (state: LocalModelRootStatus.State, identity: FileKey?) {
        guard let status = lstatus(path) else { return (.absent, nil) }
        if isSymbolicLink(status) {
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            return (.symbolicLink(destination: destination), nil)
        }
        guard isDirectory(status), access(path, R_OK | X_OK) == 0 else { return (.unreadable, nil) }
        return (.scanned, FileKey(status))
    }

    private static func lstatus(_ path: String) -> stat? {
        var status = stat()
        return Darwin.lstat(path, &status) == 0 ? status : nil
    }

    private static func isSymbolicLink(_ status: stat) -> Bool { status.st_mode & S_IFMT == S_IFLNK }
    private static func isDirectory(_ status: stat) -> Bool { status.st_mode & S_IFMT == S_IFDIR }
    private static func isRegularFile(_ status: stat) -> Bool { status.st_mode & S_IFMT == S_IFREG }

    /// 本地占用：已分配的块（与空间分析口径一致）。
    private static func allocatedBytes(_ status: stat) -> Int64 {
        max(0, Int64(status.st_blocks) * 512)
    }

    /// “sha256-<64 位十六进制>” → “sha256:<…>”。
    static func digest(fromBlobName name: String) -> String? {
        guard name.hasPrefix("sha256-") else { return nil }
        let digest = "sha256:" + name.dropFirst("sha256-".count)
        return isValidDigest(digest) ? digest : nil
    }

    static func blobName(fromDigest digest: String) -> String {
        digest.replacingOccurrences(of: ":", with: "-")
    }

    /// 只接受 ASCII 小写十六进制（0-9、a-f）；`Character.isHexDigit` 还接受全角字符，不用。
    static func isValidDigest(_ digest: String) -> Bool {
        guard digest.hasPrefix("sha256:") else { return false }
        let hex = digest.utf8.dropFirst("sha256:".utf8.count)
        return hex.count == 64 && hex.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(max(0, rhs))
        return result.overflow ? .max : result.partialValue
    }
}
