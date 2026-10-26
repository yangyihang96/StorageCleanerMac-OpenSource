import Foundation
import XCTest
@testable import StorageCleanerMac

/// 数据夹具使用系统临时目录；经过移动、回执或严格路径校验的夹具使用隐藏家目录。
/// 不覆盖进程 HOME，也不修改 PathSafety 的全局状态。
enum TestFileSystem {
    /// 仅用于偏好、普通 JSON、纯解析等不经过产品文件操作安全检查的夹具。
    static func uniqueRoot(_ label: String = "Home") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-Tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        return URL(fileURLWithPath: PathSafety.lexicalPath(url.path), isDirectory: true)
    }

    static func makeHome(
        for testCase: XCTestCase,
        createDirectory: (URL) throws -> Void = TestFileSystem.createDirectory(at:)
    ) throws -> URL {
        let home = uniqueRoot()
        registerCleanup(of: home, for: testCase)
        try initialize(root: home) { try createHome(at: home, createDirectory: createDirectory) }
        return home
    }

    /// D48 / fix2：只返回唯一地址，由夹具创建并在自己的 defer 中清理。
    /// 不落入真实 Library，也不要求产品接受系统临时目录或测试专用例外。
    static func uniqueOperationRoot(_ purpose: String) -> URL {
        let label = purpose.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return operationFixtureParent.appendingPathComponent(
            ".storage-cleaner-\(label.isEmpty ? "fixture" : label)-\(UUID().uuidString)", isDirectory: true)
    }

    private static var operationFixtureParent: URL {
        // Sandboxed lanes can keep owned operation fixtures in this worktree.
        // Opt-in only: never change HOME or relax production path validation.
        if let configured = ProcessInfo.processInfo.environment["STORAGE_CLEANER_TEST_OPERATION_ROOT"] {
            let path = PathSafety.lexicalPath(configured)
            let buildRoot = SwiftSourceScanning.projectRoot.appendingPathComponent(".build").path
            precondition(path.hasPrefix(buildRoot + "/") && !PathSafety.containsSymbolicLinkComponent(in: path),
                         "Operation fixture override must be inside this worktree's .build")
            return URL(fileURLWithPath: path, isDirectory: true)
        } else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
    }

    /// 需要 Library/Caches 等规则结构时，注入隔离根内的 home，而非真实家目录。
    static func makeOperationHome(
        for testCase: XCTestCase, purpose: String = "operation",
        createDirectory: (URL) throws -> Void = TestFileSystem.createDirectory(at:)
    ) throws -> URL {
        let root = uniqueOperationRoot(purpose)
        let home = root.appendingPathComponent("home", isDirectory: true)
        registerCleanup(of: root, for: testCase)
        try initialize(root: root) { try createHome(at: home, createDirectory: createDirectory) }
        return home
    }

    private static func createHome(at home: URL, createDirectory: (URL) throws -> Void) throws {
        for relative in ["", "Applications", "Library/Caches", "Library/Preferences",
                         "Library/Containers", "Library/Application Support", ".Trash"] {
            try createDirectory(home.appendingPathComponent(relative))
        }
    }

    static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// 根的责任在调用创建闭包之前确定；部分创建失败时清理并保留原错误。
    static func initialize<Value>(root: URL, _ body: () throws -> Value) throws -> Value {
        do { return try body() }
        catch { remove(root); throw error }
    }

    /// 只传本测试拥有的唯一根；不存在可重复清理，其他删除错误必须报告。
    static func remove(
        _ root: URL, file: StaticString = #filePath, line: UInt = #line,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        if let reason = ownership.cleanupBlock(for: root.path) {
            XCTFail("后台任务未退出，保留本测试夹具 \(root.path)：\(reason)", file: file, line: line)
            return
        }
        do { try removeItem(root) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return
        } catch {
            XCTFail("无法删除本测试夹具 \(root.path)：\(error)", file: file, line: line)
        }
    }

    /// 只用于本测试拥有的唯一夹具根：删除前清掉锁定标志、给目录补回属主权限。
    /// 复制保真测试会造出 uchg／只读目录，不解锁就删不掉；不跟随符号链接，不碰根以外的路径。
    static func unlockOwnedTree(_ root: URL) {
        guard isFixtureRoot(root), ownership.cleanupBlock(for: root.path) == nil else { return }
        func unlock(_ path: String) {
            var status = stat()
            guard lstat(path, &status) == 0 else { return }
            if status.st_flags != 0 { _ = lchflags(path, 0) }
            // Fixtures may carry "deny delete" ACLs; an empty extended ACL lifts
            // them in the same owned tree, like the flags above.
            if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
                acl_free(UnsafeMutableRawPointer(acl))
                if let empty = acl_init(0) {
                    _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, empty)
                    acl_free(UnsafeMutableRawPointer(empty))
                }
            }
            if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                _ = chmod(path, (status.st_mode & 0o7777) | 0o700)
            }
        }
        unlock(root.path)
        // The enumerator descends into a directory after returning it, so a
        // directory made writable here is listable before its children.
        guard let entries = FileManager.default.enumerator(atPath: root.path) else { return }
        for case let relative as String in entries {
            unlock(root.appendingPathComponent(relative).path)
        }
    }

    static func registerCleanup(of root: URL, for testCase: XCTestCase) {
        registerOwnership(of: root, for: testCase)
        testCase.addTeardownBlock { remove(root) }
    }

    private static let ownership = TestFixtureOwnership()

    /// Failed joining is a test failure, never permission to delete a live fixture.
    /// Preserve all registered roots for the main session to inspect; no delete retry.
    static func preventCleanup(ownedBy owner: ObjectIdentifier, unfinishedTasks: [String]) {
        ownership.preventCleanup(owner: owner, reason: unfinishedTasks.joined(separator: ", "))
    }

    /// Only a UUID fixture root may be registered. A path merely under HOME or
    /// temporaryDirectory is not proof that this test owns it.
    static func registerOwnership(of root: URL, for testCase: XCTestCase) {
        guard isFixtureRoot(root) else {
            XCTFail("只能登记唯一测试夹具根：\(root.lastPathComponent)")
            return
        }
        let owner = ObjectIdentifier(testCase)
        ownership.insert(root.path, owner: owner)
        testCase.addTeardownBlock { ownership.remove(root.path, owner: owner) }
    }

    static func requireOwned(_ url: URL, for testCase: XCTestCase, operation: Bool = false) throws -> URL {
        let path = PathSafety.lexicalPath(url.path)
        guard url.isFileURL,
              ownership.contains(path, owner: ObjectIdentifier(testCase), operation: operation),
              !(try hasUnsafeAncestor(path)) else {
            throw TestFixtureOwnershipError.unownedPath
        }
        return url
    }

    static func requireOwnedData(_ url: URL, for testCase: XCTestCase) throws -> URL {
        guard TestPreferenceDomain.isTemporarySuiteName(url.appendingPathComponent("isolation-check").path) else {
            throw TestFixtureOwnershipError.unownedPath
        }
        return try requireOwned(url, for: testCase)
    }

    /// Existing ancestors must be directories/files, never user symlinks. Missing
    /// leaves are allowed because journals and JSON files are created later.
    private static func hasUnsafeAncestor(_ path: String) throws -> Bool {
        let canonical = try OperationFileLock.systemAliasResolvedPath(path)
        var current = URL(fileURLWithPath: "/")
        for component in URL(fileURLWithPath: canonical).pathComponents.dropFirst() {
            current.appendPathComponent(component)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return true }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return false
            }
        }
        return false
    }

    static func requireOwned(_ journal: CleanupReportJournal, for testCase: XCTestCase) throws -> CleanupReportJournal {
        _ = try requireOwned(journal.directory, for: testCase, operation: true)
        return journal
    }

    static func requireOwned(_ environment: FileAnalysisTrashEnvironment, for testCase: XCTestCase) throws -> FileAnalysisTrashEnvironment {
        for path in [environment.homePath, environment.appDataPath, environment.userTrashPath] {
            _ = try requireOwned(URL(fileURLWithPath: path), for: testCase, operation: true)
        }
        _ = try requireOwned(environment.journal, for: testCase)
        return environment
    }

    private static func isFixtureRoot(_ root: URL) -> Bool {
        let path = PathSafety.lexicalPath(root.path)
        let normalized = URL(fileURLWithPath: path)
        let name = normalized.lastPathComponent
        guard name.count > 37, UUID(uuidString: String(name.suffix(36))) != nil else { return false }
        if normalized.deletingLastPathComponent().path == operationFixtureParent.path {
            return name.hasPrefix(".storage-cleaner-")
        }
        if normalized.deletingLastPathComponent().path == PathSafety.lexicalPath(FileManager.default.homeDirectoryForCurrentUser.path) {
            return name.hasPrefix(".storage-cleaner-")
        }
        return normalized.deletingLastPathComponent().path == PathSafety.lexicalPath(FileManager.default.temporaryDirectory.path)
            && name.hasPrefix("StorageCleanerMac-Tests-")
    }

    static func analysisEnvironment(home: URL) -> FileAnalysisTrashEnvironment {
        let trash = home.appendingPathComponent(".Trash")
        return FileAnalysisTrashEnvironment(
            journal: CleanupReportJournal(directory: home.appendingPathComponent("receipts")),
            moveToTrash: { source in
                let target = trash.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: target)
                return target
            },
            metadata: FoundationReadOnlyFileSystem(),
            homePath: home.path,
            appDataPath: home.appendingPathComponent("app-data").path,
            excludedPaths: { [] }, isCloudFolder: { _ in false }, isReadOnlyVolume: { _ in false },
            userTrashPath: trash.path
        )
    }
}

private enum TestFixtureOwnershipError: Error { case unownedPath }

private final class TestFixtureOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [ObjectIdentifier: Set<String>] = [:]
    private var blockedCleanup: [String: String] = [:]
    func preventCleanup(owner: ObjectIdentifier, reason: String) {
        lock.withLock {
            for root in roots[owner, default: []] { blockedCleanup[root] = reason }
        }
    }
    func cleanupBlock(for path: String) -> String? {
        let normalized = PathSafety.lexicalPath(path)
        return lock.withLock {
            blockedCleanup.first { root, _ in
                normalized == root || normalized.hasPrefix(root + "/") || root.hasPrefix(normalized + "/")
            }?.value
        }
    }
    func insert(_ path: String, owner: ObjectIdentifier) {
        lock.withLock { _ = roots[owner, default: []].insert(PathSafety.lexicalPath(path)) }
    }
    func remove(_ path: String, owner: ObjectIdentifier) {
        lock.withLock {
            _ = roots[owner]?.remove(PathSafety.lexicalPath(path))
            if roots[owner]?.isEmpty == true { roots[owner] = nil }
        }
    }
    func contains(_ path: String, owner: ObjectIdentifier, operation: Bool) -> Bool {
        lock.withLock {
            roots[owner, default: []].contains { root in
                (!operation || URL(fileURLWithPath: root).lastPathComponent.hasPrefix(".storage-cleaner-"))
                    && (path == root || path.hasPrefix(root + "/"))
            }
        }
    }
}
