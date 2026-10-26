import Darwin
import Foundation

/// D182: metadata-only, descriptor-relative traversal. The helper supplies only
/// SystemCacheID.directoryPath; arbitrary paths exist here for isolated tests.
public enum SystemCacheClearing {
    public struct Limits: Sendable {
        public var seconds: TimeInterval
        public var entries: Int
        public var depth: Int
        public init(seconds: TimeInterval = 30, entries: Int = 1_000_000, depth: Int = 64) {
            self.seconds = seconds; self.entries = entries; self.depth = min(64, max(0, depth))
        }
    }

    public static func inventory(_ cache: SystemCacheID, limits: Limits = Limits()) -> SystemCacheInventoryItem {
        inventory(cache, at: cache.directoryPath, limits: limits)
    }

    /// A fast, metadata-only recheck during the fifteen-second commit window.
    public static func directoryIdentity(_ cache: SystemCacheID) -> SystemCacheInventoryItem {
        do {
            let opened = try openDirectory(cache.directoryPath)
            return .init(cache: cache, device: device(opened.status), inode: UInt64(opened.status.st_ino))
        } catch { return .init(cache: cache, failure: reason(error)) }
    }

    // Internal path injection is for tests; the root helper uses the identifier API.
    static func inventory(_ cache: SystemCacheID, at path: String, limits: Limits = Limits()) -> SystemCacheInventoryItem {
        do {
            let opened = try openDirectory(path)
            defer { withExtendedLifetime(opened) {} }
            let walker = Walker(limits: limits, removing: false)
            walker.walk(opened.fd, device: opened.status.st_dev, depth: 0, anchors: opened.anchors)
            return .init(cache: cache, allocatedBytes: walker.bytes, entryCount: walker.visited,
                         device: device(opened.status), inode: UInt64(opened.status.st_ino), failure: walker.failure)
        } catch {
            return .init(cache: cache, failure: reason(error))
        }
    }

    /// Removes children only. The opened target directory is never unlinked.
    public static func removeContents(ofDirectoryAt path: String, expectedDevice: UInt64,
                                      expectedInode: UInt64) -> SystemCacheRemovalResult {
        removeContents(ofDirectoryAt: path, expectedDevice: expectedDevice, expectedInode: expectedInode,
                       limits: Limits(seconds: 120), beforeOpenDirectory: nil)
    }

    static func removeContents(ofDirectoryAt path: String, expectedDevice: UInt64, expectedInode: UInt64,
                               limits: Limits, beforeOpenDirectory: ((Int32, [CChar]) -> Void)? = nil) -> SystemCacheRemovalResult {
        do {
            let opened = try openDirectory(path)
            defer { withExtendedLifetime(opened) {} }
            guard device(opened.status) == expectedDevice, UInt64(opened.status.st_ino) == expectedInode else {
                throw SystemCacheFailure.identityChanged
            }
            let walker = Walker(limits: limits, removing: true, beforeOpenDirectory: beforeOpenDirectory)
            walker.walk(opened.fd, device: opened.status.st_dev, depth: 0, anchors: opened.anchors)
            return .init(deletedEntries: walker.deleted, freedBytes: walker.bytes,
                         skippedEntries: walker.skipped, failure: walker.failure)
        } catch {
            return .init(failure: reason(error))
        }
    }

    private static func reason(_ error: any Error) -> String {
        (error as? SystemCacheFailure ?? .io).rawValue
    }
    private static func device(_ status: stat) -> UInt64 { UInt64(bitPattern: Int64(status.st_dev)) }
    private static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
    }
    private static func allocated(_ status: stat) -> Int64 {
        let blocks = max(0, Int64(status.st_blocks))
        return blocks > Int64.max / 512 ? Int64.max : blocks * 512
    }
    private static func sum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        lhs > Int64.max - rhs ? Int64.max : lhs + rhs
    }

    private struct Anchor {
        let parent: Int32
        let name: [CChar]
        let status: stat
        var unchanged: Bool {
            var current = stat()
            return name.withUnsafeBufferPointer { fstatat(parent, $0.baseAddress!, &current, AT_SYMLINK_NOFOLLOW) } == 0
                && same(status, current)
        }
    }
    private final class OpenedDirectory {
        var descriptors: [Int32] = []
        var anchors: [Anchor] = []
        var status = stat()
        var fd: Int32 { descriptors.last! }
        deinit { for fd in descriptors.reversed() { close(fd) } }
    }
    private static func openDirectory(_ path: String) throws -> OpenedDirectory {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path.utf8.count < 4_096, !path.utf8.contains(0),
              parts.count > 1, parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SystemCacheFailure.directoryUnavailable
        }
        let opened = OpenedDirectory()
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw SystemCacheFailure.directoryUnavailable }
        opened.descriptors.append(root)
        for part in parts.dropFirst() {
            let name = Array(String(part).utf8CString)
            let parent = opened.fd
            let next = name.withUnsafeBufferPointer {
                openat(parent, $0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw SystemCacheFailure.directoryUnavailable }
            opened.descriptors.append(next)
            var info = stat()
            guard fstat(next, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw SystemCacheFailure.directoryUnavailable
            }
            let anchor = Anchor(parent: parent, name: name, status: info)
            guard anchor.unchanged else { throw SystemCacheFailure.identityChanged }
            opened.anchors.append(anchor)
            opened.status = info
        }
        guard opened.anchors.allSatisfy(\.unchanged) else { throw SystemCacheFailure.identityChanged }
        return opened
    }

    private final class Walker {
        let limits: Limits
        let deadline: TimeInterval
        let removing: Bool
        let beforeOpenDirectory: ((Int32, [CChar]) -> Void)?
        var visited = 0
        var deleted = 0
        var skipped = 0
        var bytes: Int64 = 0
        var failure: String?
        var stopped = false

        init(limits: Limits, removing: Bool, beforeOpenDirectory: ((Int32, [CChar]) -> Void)? = nil) {
            self.limits = limits; self.removing = removing; self.beforeOpenDirectory = beforeOpenDirectory
            deadline = ProcessInfo.processInfo.systemUptime + max(0, limits.seconds)
        }
        func skip(_ reason: SystemCacheFailure) {
            skipped += 1
            if failure == nil { failure = reason.rawValue }
        }
        func withinBudget() -> Bool {
            guard !stopped else { return false }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                skip(.timeLimit); failure = SystemCacheFailure.timeLimit.rawValue; stopped = true
            } else if visited >= limits.entries {
                skip(.entryLimit); failure = SystemCacheFailure.entryLimit.rawValue; stopped = true
            }
            return !stopped
        }
        func walk(_ fd: Int32, device: dev_t, depth: Int, anchors: [Anchor]) {
            guard anchors.allSatisfy(\.unchanged) else { skip(.identityChanged); return }
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { skip(.io); return }
            guard let stream = fdopendir(copy) else { close(copy); skip(.io); return }
            defer { closedir(stream) }
            while !stopped {
                // Time is checked even for empty directories and dot entries.
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    skip(.timeLimit); failure = SystemCacheFailure.timeLimit.rawValue; stopped = true; return
                }
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { skip(.io) }
                    return
                }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    Array(raw.prefix { $0 != 0 }.map { CChar(bitPattern: $0) }) + [0]
                }
                if name == [46, 0] || name == [46, 46, 0] { continue }
                guard withinBudget() else { return }
                guard anchors.allSatisfy(\.unchanged) else { skip(.identityChanged); return }
                visited += 1
                var info = stat()
                guard name.withUnsafeBufferPointer({ fstatat(fd, $0.baseAddress!, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    skip(.io); continue
                }
                guard info.st_dev == device else { skip(.crossDevice); continue }
                let isDirectory = info.st_mode & S_IFMT == S_IFDIR
                let anchor = Anchor(parent: fd, name: name, status: info)
                if !removing { bytes = sum(bytes, allocated(info)) }
                if isDirectory {
                    guard depth < limits.depth else { skip(.depthLimit); continue }
                    beforeOpenDirectory?(fd, name)
                    let child = name.withUnsafeBufferPointer {
                        openat(fd, $0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                    guard child >= 0 else { skip(.identityChanged); continue }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, same(info, opened), opened.st_dev == device,
                          anchor.unchanged else { skip(.identityChanged); continue }
                    walk(child, device: device, depth: depth + 1, anchors: anchors + [anchor])
                }
                if removing {
                    guard !stopped, anchors.allSatisfy(\.unchanged), anchor.unchanged else {
                        skip(.identityChanged); continue
                    }
                    // The final stat is immediately before unlink; symlinks use
                    // flags 0, so even a raced-in link can never expose its target.
                    let removed = name.withUnsafeBufferPointer {
                        unlinkat(fd, $0.baseAddress!, isDirectory ? AT_REMOVEDIR : 0)
                    }
                    if removed == 0 {
                        deleted += 1; bytes = sum(bytes, allocated(info))
                    } else { skip(.io) }
                }
            }
        }
    }
}
