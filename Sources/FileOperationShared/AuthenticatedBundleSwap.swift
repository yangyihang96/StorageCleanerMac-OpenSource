import Darwin
import Foundation

/// Root replacement's transaction engine is shared so faults exercise the
/// actual cleanup/rollback policy without running a privileged helper.
public enum AuthenticatedBundleSwap {
    public enum Event: Sendable, Equatable { case beforeSwap, afterSwap, beforeCleanup, beforeRollback }
    public enum Failure: LocalizedError, Sendable {
        case recoveryRequired(old: String, staged: String, journal: String)
        public var errorDescription: String? {
            switch self { case let .recoveryRequired(old, staged, journal): "回滚失败；保留旧应用：\(old)；staging：\(staged)；journal：\(journal)" }
        }
    }
    public struct Journal: Codable, Sendable {
        public let destination: URL
        public let staged: URL
        public let candidateSHA256: String
        public let originalSHA256: String
        public var phase: String
    }
    public static func cleanupStaging(_ staging: URL, journal: URL) {
        guard !FileManager.default.fileExists(atPath: journal.path) else { return }
        try? FileManager.default.removeItem(at: staging)
    }
    public static func replace(destination: URL, staged: URL, digest: String, journal: URL,
        event: (Event) throws -> Void = { _ in }, verify: (URL) throws -> Void) throws {
        let original = try AuthenticatedApplicationDigest.compute(destination)
        var record = Journal(destination: destination, staged: staged, candidateSHA256: digest, originalSHA256: original, phase: "prepared")
        func save() throws { try JSONEncoder().encode(record).write(to: journal, options: .atomic) }
        func swap() throws {
            let status = staged.path.withCString { a in destination.path.withCString { b in renamex_np(a, b, UInt32(RENAME_SWAP)) } }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        try save()
        var exchanged = false
        var restored = false
        do {
            try event(.beforeSwap)
            try AuthenticatedApplicationDigest.authenticateCopy(staged, expectedSHA256: digest)
            try swap(); exchanged = true
            record.phase = "exchanged"; try save()
            try event(.afterSwap)
            try AuthenticatedApplicationDigest.authenticateCopy(destination, expectedSHA256: digest)
            try verify(destination)
            try event(.beforeCleanup)
            try AuthenticatedApplicationDigest.authenticateCopy(destination, expectedSHA256: digest)
            try AuthenticatedApplicationDigest.authenticateCopy(staged, expectedSHA256: original)
            try FileManager.default.removeItem(at: staged)
            exchanged = false
            try FileManager.default.removeItem(at: journal)
        } catch {
            if exchanged {
                do {
                    try event(.beforeRollback)
                    try swap()
                    restored = true
                    try AuthenticatedApplicationDigest.authenticateCopy(destination, expectedSHA256: original)
                    try FileManager.default.removeItem(at: staged)
                    try FileManager.default.removeItem(at: journal)
                } catch {
                    record.phase = "rollbackFailed"; try? save()
                    throw Failure.recoveryRequired(old: restored ? destination.path : staged.path, staged: staged.path, journal: journal.path)
                }
            } else { try? FileManager.default.removeItem(at: journal) }
            throw error
        }
    }
}
