import AppKit
import Darwin
import Foundation
import Security

enum UniversalBinarySkip: Error, Hashable, Sendable {
    case notOwned, notWritable, apple, appStore, ownApp, running, signature, changed, unsafeBundle
    case noNativeSlice, notAPFS, cloneFailed, gatekeeper, unavailable, cancelled

    var title: String {
        switch self {
        case .notOwned: L10n.text("属于 root 或其他用户", "Owned by root or another user")
        case .notWritable: L10n.text("应用或所在文件夹不可写", "App or its folder is not writable")
        case .apple: L10n.text("Apple 平台应用", "Apple platform app")
        case .appStore: L10n.text("来自 App Store", "From the App Store")
        case .ownApp: L10n.text("本应用", "This app")
        case .running: L10n.text("应用正在运行，请先退出", "App is running; quit it first")
        case .signature: L10n.text("签名未通过严格校验", "Signature did not pass strict validation")
        case .changed: L10n.text("扫描后应用有变化，请重新扫描", "App changed since scanning; scan again")
        case .unsafeBundle: L10n.text("包内有外部链接、特殊文件或无法确认的项目", "Bundle contains an external link, special file or unverified item")
        case .noNativeSlice: L10n.text("没有可安全移除的芯片代码", "No architecture code can be safely removed")
        case .notAPFS: L10n.text("所在磁盘不是可克隆的 APFS 卷", "Disk is not a cloneable APFS volume")
        case .cloneFailed: L10n.text("无法创建 APFS 克隆", "Could not create an APFS clone")
        case .gatekeeper: L10n.text("瘦身副本未通过系统安全评估", "Thinned copy did not pass the system security assessment")
        case .unavailable: L10n.text("系统安全评估不可用", "System security assessment is unavailable")
        case .cancelled: L10n.text("已停止", "Stopped")
        }
    }
}

enum UniversalBinarySafety {
    /// Only the just-created clone, tracked by dev/inode/birth, is ever deleted
    /// here. Integration review: kept out of UniversalBinaryService, which
    /// moves the original to the Trash, so that file deletes nothing (D98 ⑤).
    static func discardClone(_ clone: URL, identity: FileIdentity) throws {
        guard isStagingName(clone.lastPathComponent), identity.entryKind == .directory,
              !PathSafety.containsSymbolicLinkComponent(in: clone.path),
              try stamp(clone).identity == identity else { throw UniversalBinarySkip.changed }
        guard removefile(clone.path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 else { throw POSIXError(.EIO) }
    }

    struct Stamp: Equatable, Sendable {
        let identity: FileIdentity
        let size: Int64
        let mode: mode_t
        let owner: uid_t
        let flags: UInt32
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
    }

    static func stamp(_ url: URL) throws -> Stamp {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_birthtimespec.tv_sec > 0 else { throw UniversalBinarySkip.changed }
        let kind: FileEntryKind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .regularFile
        case S_IFLNK: kind = .symbolicLink
        default: throw UniversalBinarySkip.unsafeBundle
        }
        return Stamp(identity: FileIdentity(deviceID: UInt64(info.st_dev), inode: info.st_ino, entryKind: kind,
            creationTimeNanoseconds: Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec)),
            size: info.st_size, mode: info.st_mode, owner: info.st_uid, flags: info.st_flags,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }

    static func isInside(_ item: URL, _ root: URL) -> Bool {
        item.path.hasPrefix(root.path + "/") && item.standardizedFileURL.path == item.path
    }

    static func isStagingName(_ name: String) -> Bool {
        guard name.hasSuffix(".app"), let marker = name.range(of: ".storagecleaner-thin-", options: .backwards) else { return false }
        return UUID(uuidString: String(name[marker.upperBound...].dropLast(4))) != nil
    }

    /// The original's descriptor survives rename and a Trash move. Resolve it without a Trash scan.
    static func trackedPath(_ descriptor: Int32, identity: FileIdentity) throws -> URL {
        var info = stat()
        guard fstat(descriptor, &info) == 0, UInt64(info.st_dev) == identity.deviceID,
              info.st_ino == identity.inode, info.st_mode & S_IFMT == S_IFDIR,
              Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec)
                == identity.creationTimeNanoseconds else { throw UniversalBinarySkip.changed }
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let status = bytes.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        guard status == 0, let end = bytes.firstIndex(of: 0), end > 0 else { throw UniversalBinarySkip.changed }
        let path = String(decoding: bytes.prefix(end).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let url = URL(fileURLWithPath: path)
        guard !PathSafety.containsSymbolicLinkComponent(in: url.path),
              try stamp(url).identity == identity else { throw UniversalBinarySkip.changed }
        return url
    }

    static func isAPFS(_ url: URL) -> Bool {
        var value = statfs()
        guard statfs(url.path, &value) == 0 else { return false }
        let name = withUnsafeBytes(of: value.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return name == "apfs" && (value.f_flags & UInt32(MNT_RDONLY)) == 0
    }

    /// Every bundle level is examined, including directories outside the Mach-O search roots.
    /// Internal relative framework links are kept; dangling and external links fail closed.
    static func tree(_ app: URL) throws -> [String: Stamp] {
        guard !PathSafety.containsSymbolicLinkComponent(in: app.path) else { throw UniversalBinarySkip.unsafeBundle }
        let root = try stamp(app)
        guard root.identity.entryKind == .directory,
              root.flags & (UInt32(SF_DATALESS) | UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND)) == 0 else {
            throw UniversalBinarySkip.unsafeBundle
        }
        var result = ["": root]
        var readFailed = false
        guard let iterator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in readFailed = true; return false }) else { throw UniversalBinarySkip.unsafeBundle }
        for case let url as URL in iterator {
            try Task.checkCancellation()
            guard isInside(url, app) else { throw UniversalBinarySkip.unsafeBundle }
            let entry = try stamp(url)
            guard entry.identity.deviceID == root.identity.deviceID,
                  entry.flags & (UInt32(SF_DATALESS) | UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND)) == 0 else {
                throw UniversalBinarySkip.unsafeBundle
            }
            if entry.identity.entryKind == .symbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                // Absolute links into the original would escape a later clone. Do not rewrite them.
                guard !target.hasPrefix("/"),
                      isInside(url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL, app),
                      isInside(url.resolvingSymlinksInPath(), app),
                      FileManager.default.fileExists(atPath: url.path) else { throw UniversalBinarySkip.unsafeBundle }
            } else {
                guard entry.owner == getuid(), entry.owner != 0 else { throw UniversalBinarySkip.notOwned }
                guard access(url.path, R_OK | W_OK) == 0 else { throw UniversalBinarySkip.notWritable }
                if entry.identity.entryKind == .regularFile {
                    var info = stat()
                    guard lstat(url.path, &info) == 0, info.st_nlink == 1 else { throw UniversalBinarySkip.unsafeBundle }
                }
            }
            result[String(url.path.dropFirst(app.path.count + 1))] = entry
        }
        guard !readFailed, try stamp(app) == root else { throw UniversalBinarySkip.changed }
        return result
    }

    static func signature(_ url: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw UniversalBinarySkip.signature
        }
    }

    static func isApple(_ url: URL) throws -> Bool {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw UniversalBinarySkip.signature }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func isRunning(_ app: URL, identifiers: [String]) async -> Bool {
        // Same owner check as requiredClosedBundleIDs, plus path containment for nested helpers.
        let checker = FoundationCleanupRunningApplicationChecker()
        for identifier in identifiers where await checker.isRunning(bundleIdentifier: identifier) { return true }
        return await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { running in
                [running.bundleURL, running.executableURL].compactMap { $0 }.contains {
                    $0.standardizedFileURL == app || isInside($0.standardizedFileURL, app)
                }
            }
        }
    }
}

/// SecAssessment is exported by Security.framework but is absent from the current public SDK.
/// Load its real constants and functions; missing symbols or an incomplete verdict refuse the operation.
enum UniversalGatekeeper {
    static func assess(_ url: URL) throws -> Bool {
        guard let library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL) else {
            throw UniversalBinarySkip.unavailable
        }
        defer { dlclose(library) }
        typealias Create = @convention(c) (CFURL, UInt64, CFDictionary, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFTypeRef>?
        typealias Result = @convention(c) (CFTypeRef, UInt64, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFDictionary>?
        func constant(_ name: String) throws -> CFString {
            guard let symbol = dlsym(library, name) else { throw UniversalBinarySkip.unavailable }
            return symbol.assumingMemoryBound(to: CFString.self).pointee
        }
        guard let make = dlsym(library, "SecAssessmentCreate"), let copy = dlsym(library, "SecAssessmentCopyResult") else {
            throw UniversalBinarySkip.unavailable
        }
        let operation = try constant("kSecAssessmentContextKeyOperation")
        let execute = try constant("kSecAssessmentOperationTypeExecute")
        let verdictKey = try constant("kSecAssessmentAssessmentVerdict")
        let context = [operation as String: execute] as CFDictionary
        var error: Unmanaged<CFError>?
        let created = unsafeBitCast(make, to: Create.self)(url as CFURL, 0, context, &error)
        if let error { _ = error.takeRetainedValue() }
        guard let assessment = created?.takeRetainedValue() else { throw UniversalBinarySkip.unavailable }
        error = nil
        let copied = unsafeBitCast(copy, to: Result.self)(assessment, 0, &error)
        if let error { _ = error.takeRetainedValue() }
        guard let result = copied?.takeRetainedValue() as? [String: Any],
              let verdict = result[verdictKey as String] as? Bool else { throw UniversalBinarySkip.unavailable }
        return verdict
    }
}
