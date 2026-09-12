import Darwin
import Foundation

struct StartupPathInspection: Hashable, Sendable {
    let URL: URL
    let exists: Bool
    let isExecutable: Bool
    let isSymbolicLink: Bool
    let symbolicLinkResolves: Bool
    let ownerID: uid_t?
    let groupID: gid_t?
    let POSIXPermissions: UInt16?
    let isGroupWritable: Bool
    let isWorldWritable: Bool
    let isInTemporaryDirectory: Bool
    let isInTrash: Bool

    var warnings: [String] {
        var result = [String]()
        if !exists { result.append("target-missing") }
        if exists, !isExecutable { result.append("target-not-executable") }
        if isSymbolicLink, !symbolicLinkResolves { result.append("unresolved-symbolic-link") }
        if isGroupWritable { result.append("group-writable") }
        if isWorldWritable { result.append("world-writable") }
        if isInTemporaryDirectory { result.append("temporary-directory-target") }
        if isInTrash { result.append("trash-target") }
        return result
    }
}

struct StartupPathValidator: Sendable {
    func inspect(_ URL: URL) -> StartupPathInspection {
        let path = URL.standardizedFileURL.path
        var linkInfo = stat()
        let linkStatus = lstat(path, &linkInfo)
        var targetInfo = stat()
        let targetStatus = stat(path, &targetInfo)
        let exists = targetStatus == 0
        let isSymbolicLink = linkStatus == 0 && (linkInfo.st_mode & S_IFMT) == S_IFLNK
        let permissions = exists ? UInt16(targetInfo.st_mode & 0o7777) : nil
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL.path
        return StartupPathInspection(
            URL: URL.standardizedFileURL,
            exists: exists,
            isExecutable: exists && access(path, X_OK) == 0,
            isSymbolicLink: isSymbolicLink,
            symbolicLinkResolves: !isSymbolicLink || exists,
            ownerID: exists ? targetInfo.st_uid : nil,
            groupID: exists ? targetInfo.st_gid : nil,
            POSIXPermissions: permissions,
            isGroupWritable: permissions.map { ($0 & 0o020) != 0 } ?? false,
            isWorldWritable: permissions.map { ($0 & 0o002) != 0 } ?? false,
            isInTemporaryDirectory: path == "/tmp" || path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/"),
            isInTrash: path == homeTrash || path.hasPrefix(homeTrash + "/")
        )
    }
}

struct StartupSignatureInspection: Hashable, Sendable {
    let isSigned: Bool
    let isValid: Bool
    let teamIdentifier: String?
    let signingIdentifier: String?
    let designatedRequirement: String?
    let status: Int32?
}

protocol StartupSignatureInspecting: Sendable {
    func inspectFresh(_ URL: URL) async -> StartupSignatureInspection
}

actor StartupCodeSignatureVerifier: StartupSignatureInspecting {
    private var cache = [String: StartupSignatureInspection]()

    func inspect(_ URL: URL) async -> StartupSignatureInspection {
        let normalized = URL.standardizedFileURL
        if let cached = cache[normalized.path] { return cached }
        let result = await Self.verify(normalized)
        cache[normalized.path] = result
        return result
    }

    /// Re-verifies the current file bytes and signing information. Management
    /// operations use this path so a scan-time cache cannot authorize a file
    /// that was replaced after the user reviewed the preview.
    func inspectFresh(_ URL: URL) async -> StartupSignatureInspection {
        let normalized = URL.standardizedFileURL
        let result = await Self.verify(normalized)
        cache[normalized.path] = result
        return result
    }

    private static func verify(_ normalized: URL) async -> StartupSignatureInspection {
        await Task.detached(priority: .utility) {
            do {
                let verification = try CodeSignatureVerifier().verifyCode(at: normalized)
                return StartupSignatureInspection(
                    isSigned: true,
                    isValid: verification.isValid,
                    teamIdentifier: verification.teamIdentifier,
                    signingIdentifier: verification.codeSigningIdentifier,
                    designatedRequirement: verification.designatedRequirement,
                    status: verification.status
                )
            } catch let error as CodeSignatureVerificationError {
                let status: Int32?
                let isSigned: Bool
                switch error {
                case .targetDoesNotExist:
                    status = nil
                    isSigned = false
                case let .cannotCreateStaticCode(value):
                    status = value
                    isSigned = false
                case let .invalidSignature(value), let .cannotReadSigningInformation(value):
                    status = value
                    isSigned = true
                }
                return StartupSignatureInspection(
                    isSigned: isSigned,
                    isValid: false,
                    teamIdentifier: nil,
                    signingIdentifier: nil,
                    designatedRequirement: nil,
                    status: status
                )
            } catch {
                return StartupSignatureInspection(
                    isSigned: false,
                    isValid: false,
                    teamIdentifier: nil,
                    signingIdentifier: nil,
                    designatedRequirement: nil,
                    status: nil
                )
            }
        }.value
    }

    func removeAllCachedResults() {
        cache.removeAll()
    }
}
