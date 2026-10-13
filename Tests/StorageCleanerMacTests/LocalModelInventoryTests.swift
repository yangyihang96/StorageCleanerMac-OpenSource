import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D86：本地 AI 模型只读盘点。夹具都在系统临时目录的假家目录里，
/// 不读取真实的 ~/.ollama 或 LM Studio 目录。
final class LocalModelInventoryTests: XCTestCase {
    private let config1 = "sha256:" + String(repeating: "1", count: 64)
    private let config2 = "sha256:" + String(repeating: "2", count: 64)
    private let sharedModel = "sha256:" + String(repeating: "a", count: 64)
    private let license = "sha256:" + String(repeating: "b", count: 64)
    private let missing = "sha256:" + String(repeating: "c", count: 64)
    private let orphan = "sha256:" + String(repeating: "d", count: 64)
    private let external = "sha256:" + String(repeating: "e", count: 64)

    func testOllamaManifestsNameModelsAndCountSharedBlobsOnce() throws {
        let home = try makeHome()
        let models = home.appendingPathComponent(".ollama/models")
        let blobs = models.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try writeJSON(["model_format": "gguf", "file_type": "Q4_K_M", "model_family": "llama"], to: blob(config1, in: blobs))
        try writeJSON(["model_format": "gguf", "file_type": "Q8_0"], to: blob(config2, in: blobs))
        try Data(repeating: 1, count: 256 * 1024).write(to: blob(sharedModel, in: blobs))
        try Data(repeating: 2, count: 8 * 1024).write(to: blob(license, in: blobs))
        try Data(repeating: 3, count: 16 * 1024).write(to: blob(orphan, in: blobs))
        let outside = try makeOutsideFile()
        try FileManager.default.createSymbolicLink(at: blob(external, in: blobs), withDestinationURL: outside)

        let library = models.appendingPathComponent("manifests/registry.ollama.ai/library/llama3")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try writeManifest(config: config1, layers: [sharedModel, license], to: library.appendingPathComponent("8b"))
        try writeManifest(config: config2, layers: [sharedModel, license], to: library.appendingPathComponent("8b-instruct"))
        let custom = models.appendingPathComponent("manifests/hf.co/user/repo")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try writeManifest(config: nil, layers: [missing], to: custom.appendingPathComponent("q4"))
        let broken = models.appendingPathComponent("manifests/registry.ollama.ai/library/broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("latest"))
        try writeManifest(config: nil, layers: ["../../etc/passwd"], to: broken.appendingPathComponent("escape"))

        let inventory = LocalModelInventoryScanner(homePath: home.path).scan()

        XCTAssertEqual(Set(inventory.models.map(\.name)), ["llama3:8b", "llama3:8b-instruct", "hf.co/user/repo:q4"])
        let base = try XCTUnwrap(inventory.models.first { $0.name == "llama3:8b" })
        XCTAssertEqual(base.source, .ollama)
        XCTAssertEqual(base.format, "GGUF · Q4_K_M")
        XCTAssertEqual(base.sharedWith, ["llama3:8b-instruct"])
        let shared = allocated(blob(sharedModel, in: blobs)) + allocated(blob(license, in: blobs))
        XCTAssertEqual(base.sharedBytes, shared)
        XCTAssertEqual(base.exclusiveBytes, allocated(blob(config1, in: blobs)))
        XCTAssertEqual(base.bytes, shared + allocated(blob(config1, in: blobs)))
        XCTAssertEqual(base.fileCount, 3)
        let custom4 = try XCTUnwrap(inventory.models.first { $0.name == "hf.co/user/repo:q4" })
        XCTAssertEqual(custom4.missingFileCount, 1)
        XCTAssertEqual(custom4.bytes, 0)
        XCTAssertEqual(custom4.format, L10n.text("Ollama 模型", "Ollama model"), "Model layer without a readable config")

        // 共享 blob 只计一次。
        let expectedTotal = shared + allocated(blob(config1, in: blobs)) + allocated(blob(config2, in: blobs))
        XCTAssertEqual(inventory.totalBytes, expectedTotal)
        XCTAssertLessThan(inventory.totalBytes, inventory.models.reduce(0) { $0 + $1.bytes })

        // 未知清单保留不计；越界 digest 也按未知处理，不拼接路径。
        XCTAssertEqual(inventory.unknownManifests, ["registry.ollama.ai/library/broken/escape", "registry.ollama.ai/library/broken/latest"])
        XCTAssertEqual(inventory.unreferencedBlobCount, 1)
        XCTAssertEqual(inventory.unreferencedBlobBytes, allocated(blob(orphan, in: blobs)))
        XCTAssertEqual(inventory.skippedSymbolicLinks, [blob(external, in: blobs).path])
        XCTAssertFalse(inventory.isIncomplete)

        let sharing = try XCTUnwrap(LocalModelInventoryPresentation.sharing(base))
        XCTAssertTrue(sharing.contains("llama3:8b-instruct"))
        XCTAssertTrue(LocalModelInventoryPresentation.notices(inventory).count >= 3)
    }

    func testLMStudioFoldersAreModelsAndSymbolicLinksAreNotFollowed() throws {
        let home = try makeHome()
        let root = home.appendingPathComponent(".lmstudio/models")
        let modelA = root.appendingPathComponent("publisher/model-a")
        let modelB = root.appendingPathComponent("publisher/model-b")
        let notes = root.appendingPathComponent("publisher/notes")
        for folder in [modelA, modelB, notes] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let gguf = modelA.appendingPathComponent("model-a-Q4_K_M.gguf")
        try Data(repeating: 4, count: 128 * 1024).write(to: gguf)
        try FileManager.default.linkItem(at: gguf, to: modelA.appendingPathComponent("copy.gguf"))
        try Data(repeating: 5, count: 64 * 1024).write(to: modelB.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: modelB.appendingPathComponent("config.json"))
        try Data("hello".utf8).write(to: notes.appendingPathComponent("readme.md"))
        let outsideFolder = try makeOutsideFolder()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("publisher/linked"), withDestinationURL: outsideFolder)
        try FileManager.default.createSymbolicLink(at: modelB.appendingPathComponent("extra.gguf"),
                                                   withDestinationURL: outsideFolder.appendingPathComponent("big.gguf"))
        // 第二个默认位置是指向第一个的符号链接：不跟随、不重复计算。
        let cache = home.appendingPathComponent(".cache/lm-studio")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("models"), withDestinationURL: root)

        let inventory = LocalModelInventoryScanner(homePath: home.path).scan()

        XCTAssertEqual(inventory.models.map(\.name), ["publisher/model-a", "publisher/model-b"])
        let a = inventory.models[0]
        XCTAssertEqual(a.source, .lmStudio)
        XCTAssertEqual(a.format, "GGUF")
        XCTAssertEqual(a.bytes, allocated(gguf), "Hard links count once")
        XCTAssertEqual(inventory.models[1].format, "Safetensors")
        XCTAssertEqual(inventory.totalBytes, a.bytes + inventory.models[1].bytes)
        XCTAssertEqual(Set(inventory.skippedSymbolicLinks), [
            root.appendingPathComponent("publisher/linked").path, modelB.appendingPathComponent("extra.gguf").path,
        ])
        let states = Dictionary(uniqueKeysWithValues: inventory.roots.map { ($0.path, $0.state) })
        XCTAssertEqual(states[root.path], .scanned)
        XCTAssertEqual(states[cache.appendingPathComponent("models").path], .symbolicLink(destination: root.path))
        XCTAssertEqual(states[home.appendingPathComponent(".ollama/models").path], .absent)
    }

    func testMissingFoldersSymbolicRootsLimitsAndCancellationAreSafe() throws {
        let empty = try makeHome()
        let none = LocalModelInventoryScanner(homePath: empty.path).scan()
        XCTAssertFalse(none.hasAnyRoot)
        XCTAssertTrue(none.models.isEmpty)
        XCTAssertEqual(LocalModelInventoryPresentation.summary(none),
                       L10n.text("没有找到 Ollama 或 LM Studio 的模型文件夹", "No Ollama or LM Studio model folder found"))

        // 模型根本身是指向外部的符号链接：不跟随。
        let linkedHome = try makeHome()
        let outside = try makeOutsideFolder()
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkedHome.appendingPathComponent(".ollama"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedHome.appendingPathComponent(".ollama/models"), withDestinationURL: outside)
        let linked = LocalModelInventoryScanner(homePath: linkedHome.path).scan()
        XCTAssertTrue(linked.models.isEmpty)
        XCTAssertEqual(linked.roots.first?.state, .symbolicLink(destination: outside.path))

        // 条目上限与取消：结果标为不完整。
        let busy = try makeHome()
        let folder = busy.appendingPathComponent(".lmstudio/models/p")
        for index in 0..<5 {
            let model = folder.appendingPathComponent("m\(index)")
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: model.appendingPathComponent("w.gguf"))
        }
        var limited = LocalModelInventoryScanner(homePath: busy.path)
        limited.entryLimit = 3
        XCTAssertTrue(limited.scan().isIncomplete)
        var cancelled = LocalModelInventoryScanner(homePath: busy.path)
        cancelled.isCancelled = { true }
        let stopped = cancelled.scan()
        XCTAssertTrue(stopped.isIncomplete)
        XCTAssertTrue(stopped.models.isEmpty)
        XCTAssertEqual(LocalModelInventoryScanner(homePath: busy.path).scan().models.count, 5)
    }

    /// 修复轮 1（P2-1）：过深的文件夹只跳过这一棵子树并单独说明，
    /// 后面的模型照常盘点，不当作“条目过多或已停止”。
    func testDeepFolderSkipsOnlyThatSubtree() throws {
        let home = try makeHome()
        let root = home.appendingPathComponent(".lmstudio/models/p")
        let deepParent = root.appendingPathComponent("model-a/a/b/c")
        let deep = deepParent.appendingPathComponent("d")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("model-a/w.gguf"))
        try Data(repeating: 2, count: 4096).write(to: deep.appendingPathComponent("deep.gguf"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("model-b"), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 4096).write(to: root.appendingPathComponent("model-b/w.gguf"))

        let inventory = LocalModelInventoryScanner(homePath: home.path).scan()
        XCTAssertEqual(inventory.models.map(\.name), ["p/model-a", "p/model-b"])
        XCTAssertEqual(inventory.models.first?.fileCount, 1, "The file below the depth limit is not counted")
        XCTAssertEqual(inventory.skippedDeepFolders, [deep.path])
        XCTAssertFalse(inventory.stoppedEarly)
        XCTAssertTrue(inventory.isIncomplete)
        let notices = LocalModelInventoryPresentation.notices(inventory)
        XCTAssertTrue(notices.contains { $0.contains(L10n.text("层级过深", "nested too deep")) }, "\(notices)")
        XCTAssertFalse(notices.contains(L10n.text("条目过多或已停止，结果不完整", "Too many entries or stopped; results are incomplete")))
    }

    /// 修复轮 1（P2-5）：manifests 里读不出的子文件夹记为不完整；
    /// 取消后不再 lstat、列目录，也不再记录跳过的链接。
    func testUnreadableManifestFolderAndCancellationStopEarly() throws {
        let home = try makeHome()
        let models = home.appendingPathComponent(".ollama/models")
        let blobs = models.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: blob(sharedModel, in: blobs))
        let library = models.appendingPathComponent("manifests/registry.ollama.ai/library")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("ok"), withIntermediateDirectories: true)
        try writeManifest(config: nil, layers: [sharedModel], to: library.appendingPathComponent("ok/latest"))
        let locked = library.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, 0o700) }

        let inventory = LocalModelInventoryScanner(homePath: home.path).scan()
        XCTAssertEqual(inventory.models.map(\.name), ["ok:latest"])
        XCTAssertEqual(inventory.unreadableFolders, [locked.path])
        XCTAssertFalse(inventory.stoppedEarly)
        XCTAssertTrue(inventory.isIncomplete)
        XCTAssertTrue(LocalModelInventoryPresentation.notices(inventory)
            .contains { $0.contains(L10n.text("无法读取", "unreadable")) })

        let busy = try makeHome()
        let publishers = busy.appendingPathComponent(".lmstudio/models")
        try FileManager.default.createDirectory(at: publishers.appendingPathComponent("p/m"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: publishers.appendingPathComponent("a-linked"), withDestinationURL: try makeOutsideFolder())
        var cancelled = LocalModelInventoryScanner(homePath: busy.path)
        cancelled.isCancelled = { true }
        let stopped = cancelled.scan()
        XCTAssertTrue(stopped.stoppedEarly)
        XCTAssertTrue(stopped.skippedSymbolicLinks.isEmpty, "Nothing is inspected after cancellation")
        XCTAssertTrue(stopped.unreadableFolders.isEmpty)
    }

    /// 修复轮 1（P2-2）：家目录以下任何一层是符号链接都不跟随
    /// （~/.ollama、~/.lmstudio、~/.cache 本身是链接）。
    func testIntermediateSymbolicLinkLayersAreNotFollowed() throws {
        let home = try makeHome()
        let outside = try makeOutsideFolder()
        let ollama = outside.appendingPathComponent("ollama")
        let blobs = ollama.appendingPathComponent("models/blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: blob(sharedModel, in: blobs))
        let library = ollama.appendingPathComponent("models/manifests/registry.ollama.ai/library/m")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try writeManifest(config: nil, layers: [sharedModel], to: library.appendingPathComponent("latest"))
        let studio = outside.appendingPathComponent("lmstudio/models/p/m")
        try FileManager.default.createDirectory(at: studio, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4096).write(to: studio.appendingPathComponent("w.gguf"))
        let cache = outside.appendingPathComponent("cache/lm-studio/models/q/n")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 4096).write(to: cache.appendingPathComponent("w.gguf"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".ollama"), withDestinationURL: ollama)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".lmstudio"),
                                                   withDestinationURL: outside.appendingPathComponent("lmstudio"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".cache"),
                                                   withDestinationURL: outside.appendingPathComponent("cache"))

        let inventory = LocalModelInventoryScanner(homePath: home.path).scan()
        XCTAssertTrue(inventory.models.isEmpty, "\(inventory.models.map(\.name))")
        XCTAssertEqual(inventory.totalBytes, 0)
        let states = Dictionary(uniqueKeysWithValues: inventory.roots.map { ($0.path, $0.state) })
        XCTAssertEqual(states[home.appendingPathComponent(".ollama/models").path],
                       .linkedAncestor(path: home.appendingPathComponent(".ollama").path, destination: ollama.path))
        XCTAssertEqual(states[home.appendingPathComponent(".lmstudio/models").path],
                       .linkedAncestor(path: home.appendingPathComponent(".lmstudio").path,
                                       destination: outside.appendingPathComponent("lmstudio").path))
        XCTAssertEqual(states[home.appendingPathComponent(".cache/lm-studio/models").path],
                       .linkedAncestor(path: home.appendingPathComponent(".cache").path,
                                       destination: outside.appendingPathComponent("cache").path))
        let line = LocalModelInventoryPresentation.rootLine(try XCTUnwrap(inventory.roots.first))
        XCTAssertTrue(line.contains(L10n.text("是符号链接，未跟随", "is a symbolic link, not followed")), line)
    }

    /// 修复轮 1（P2-3）：清单读取先 open(O_NOFOLLOW|O_NONBLOCK) 再 fstat，
    /// 链接、FIFO、文件夹与超限文件一律不读，FIFO 不会卡住。
    func testRegularFileReadRejectsLinksFifosFoldersAndOversizedFiles() throws {
        let root = try makeHome()
        let file = root.appendingPathComponent("manifest.json")
        try Data("{\"a\":1}".utf8).write(to: file)
        XCTAssertEqual(LocalModelInventoryScanner.readRegularFile(at: file.path, byteLimit: 1 << 20), Data("{\"a\":1}".utf8))
        XCTAssertEqual(LocalModelInventoryScanner.readRegularFile(at: file.path, byteLimit: 7), Data("{\"a\":1}".utf8),
                       "Exactly at the limit is read")
        XCTAssertNil(LocalModelInventoryScanner.readRegularFile(at: file.path, byteLimit: 6))

        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(LocalModelInventoryScanner.readRegularFile(at: link.path, byteLimit: 1 << 20))

        let fifo = root.appendingPathComponent("fifo.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertNil(LocalModelInventoryScanner.readRegularFile(at: fifo.path, byteLimit: 1 << 20))
        XCTAssertNil(LocalModelInventoryScanner.readRegularFile(at: root.path, byteLimit: 1 << 20))
        XCTAssertNil(LocalModelInventoryScanner.readRegularFile(at: root.appendingPathComponent("missing").path, byteLimit: 1 << 20))
    }

    func testNamesDigestsAndReadOnlyPresentation() {
        XCTAssertEqual(LocalModelInventoryScanner.ollamaModelName(relativePath: "registry.ollama.ai/library/qwen2/7b"), "qwen2:7b")
        XCTAssertEqual(LocalModelInventoryScanner.ollamaModelName(relativePath: "registry.ollama.ai/someone/tool/latest"), "someone/tool:latest")
        XCTAssertEqual(LocalModelInventoryScanner.ollamaModelName(relativePath: "hf.co/org/repo/q8"), "hf.co/org/repo:q8")
        XCTAssertEqual(LocalModelInventoryScanner.digest(fromBlobName: "sha256-" + String(repeating: "f", count: 64)),
                       "sha256:" + String(repeating: "f", count: 64))
        XCTAssertNil(LocalModelInventoryScanner.digest(fromBlobName: "sha256-xyz"))
        XCTAssertNil(LocalModelInventoryScanner.digest(fromBlobName: "sha256-" + String(repeating: "F", count: 64)))
        XCTAssertFalse(LocalModelInventoryScanner.isValidDigest("sha256:../../x"))
        // 修复轮 1（P2-4）：只认 ASCII 十六进制，全角字符不算。
        XCTAssertFalse(LocalModelInventoryScanner.isValidDigest("sha256:" + String(repeating: "\u{FF41}", count: 64)))
        XCTAssertFalse(LocalModelInventoryScanner.isValidDigest("sha256:" + String(repeating: "\u{FF11}", count: 64)))
        XCTAssertNil(LocalModelInventoryScanner.digest(fromBlobName: "sha256-" + String(repeating: "\u{FF41}", count: 64)))
        XCTAssertTrue(LocalModelInventoryScanner.isValidDigest("sha256:" + String(repeating: "0a", count: 32)))
        XCTAssertEqual(LocalModelInventoryScanner.lmStudioFormat(fileName: "a.GGUF"), "GGUF")
        XCTAssertNil(LocalModelInventoryScanner.lmStudioFormat(fileName: "readme.md"))
        XCTAssertTrue(LocalModelInventoryPresentation.readOnlyNote.contains(L10n.text("删除模型后需要重新下载", "must be downloaded again")))
    }

    /// 本批只读：盘点与界面里没有任何删除或移到废纸篓的调用。
    func testInventoryOffersNoDeletion() throws {
        for path in ["Services/LocalModelInventory.swift", "Views/FilesLightfield/LocalModelInventoryView.swift"] {
            let text = try source(path)
            for token in ["removeItem", "trashItem", "moveItem", "unlink(", "rmdir(", "FileManager.default.createFile",
                          "write(to:", "requestTrash", "moveToTrash"] {
                XCTAssertFalse(text.contains(token), "\(path) \(token)")
            }
        }
    }

    // MARK: - Helpers

    private func makeHome() throws -> URL {
        let root = TestFileSystem.uniqueRoot("LocalModels")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeOutsideFolder() throws -> URL {
        let root = TestFileSystem.uniqueRoot("LocalModelsOutside")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 32 * 1024).write(to: root.appendingPathComponent("big.gguf"))
        return root
    }

    private func makeOutsideFile() throws -> URL {
        try makeOutsideFolder().appendingPathComponent("big.gguf")
    }

    private func blob(_ digest: String, in blobs: URL) -> URL {
        blobs.appendingPathComponent(digest.replacingOccurrences(of: ":", with: "-"))
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func writeManifest(config: String?, layers: [String], to url: URL) throws {
        var object: [String: Any] = [
            "schemaVersion": 2,
            "layers": layers.map { ["mediaType": "application/vnd.ollama.image.model", "digest": $0, "size": 1] },
        ]
        if let config { object["config"] = ["mediaType": "application/vnd.docker.container.image.v1+json", "digest": config] }
        try writeJSON(object, to: url)
    }

    private func allocated(_ url: URL) -> Int64 {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return -1 }
        return Int64(status.st_blocks) * 512
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
    }
}
