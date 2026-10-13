import CryptoKit
import Darwin
import Foundation

/// Source trust for brew/mas and their directories. A standard Homebrew
/// install keeps bin/ as user:admin 0775. Accepting that layout deliberately
/// trusts local administrators to modify these sources. Other group or world
/// write remains forbidden.
enum AppUpdateSourcePermissions {
    static let adminGroupID: UInt32 = 80

    static func isTrusted(owner: UInt32, group: UInt32, mode: UInt16, user: UInt32 = getuid()) -> Bool {
        (owner == 0 || owner == user) && mode & 0o002 == 0 && (mode & 0o020 == 0 || group == adminGroupID)
    }
}

struct AppUpdateExecutableIdentity: Sendable, Equatable {
    let url: URL
    let resolvedURL: URL
    let inode: UInt64
    let device: UInt64
    let owner: UInt32
    let mode: UInt16
    let sha256: String
    static func capture(_ url: URL) throws -> Self {
        try capture(url, directoryAttributes: { try FileManager.default.attributesOfItem(atPath: $0.path) })
    }
    /// The injected directory stat reader lets tests exercise the same capture
    /// walk without changing ownership on the host's Homebrew directories.
    static func capture(_ url: URL, directoryAttributes: (URL) throws -> [FileAttributeKey: Any]) throws -> Self {
        let requested = url.standardizedFileURL; let resolved = requested.resolvingSymlinksInPath()
        for path in Set([requested, resolved]) {
        var parent = path.deletingLastPathComponent()
        while parent.path != "/" {
            let attributes = try directoryAttributes(parent)
            guard let owner = attributes[.ownerAccountID] as? NSNumber,
                  AppUpdateSourcePermissions.isTrusted(owner: owner.uint32Value,
                      group: (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? UInt32.max,
                      mode: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777)
            else { throw AppUpdateAuthorizationError.sourceChanged(requested.path) }
            parent.deleteLastPathComponent()
        }
        }
        let fd = open(resolved.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AppUpdateAuthorizationError.sourceChanged(requested.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 != 0,
            AppUpdateSourcePermissions.isTrusted(owner: info.st_uid, group: info.st_gid, mode: UInt16(info.st_mode & 0o7777)) else { throw AppUpdateAuthorizationError.sourceChanged(requested.path) }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return .init(url: requested, resolvedURL: resolved, inode: UInt64(info.st_ino), device: UInt64(info.st_dev), owner: info.st_uid,
            mode: UInt16(info.st_mode), sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    func validate() throws {
        guard try Self.capture(url) == self else { throw AppUpdateAuthorizationError.sourceChanged(url.path) }
    }
}
