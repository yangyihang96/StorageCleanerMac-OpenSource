import Darwin
import Foundation

public enum HelperClientSigningPolicy {
    /// Certificate data equality preserves the original complete-chain check.
    /// Build numbers and protocol versions are deliberately not credentials.
    public static func permits(helperCertificates: [Data], clientCertificates: [Data],
                               clientIdentifier: String, expectedIdentifier: String) -> Bool {
        !helperCertificates.isEmpty && helperCertificates == clientCertificates
            && clientIdentifier == expectedIdentifier
    }
}

/// Evidence for a file replacement, never caller authority. Read before and
/// after signature validation; unknown, symlinked or non-regular files fail closed.
public struct HelperExecutableStamp: Equatable, Sendable {
    public let token: String
    public init(token: String) { self.token = token }

    public static func read(at url: URL) -> Self? {
        guard url.isFileURL,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { return nil }
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return .init(token: "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)")
    }
}

public enum HelperUpgradeSafety {
    /// All booleans are derived from Security/audit-token evidence inside the
    /// daemon. There is no upgrade RPC, caller PID, build number or JSON authority.
    public static func shouldYield(originalClientValid: Bool, installedTeamClientValid: Bool,
                                   startupStamp: HelperExecutableStamp?, currentStamp: HelperExecutableStamp?,
                                   runningCodeHash: Data?, replacementCodeHash: Data?,
                                   runningBuild: HelperSignedBuildVersion?, replacementBuild: HelperSignedBuildVersion?,
                                   replacementSignatureValid: Bool) -> Bool {
        guard originalClientValid, installedTeamClientValid, replacementSignatureValid,
              let startupStamp, let currentStamp, startupStamp != currentStamp,
              let runningCodeHash, !runningCodeHash.isEmpty,
              let replacementCodeHash, !replacementCodeHash.isEmpty,
              let runningBuild, let replacementBuild, replacementBuild > runningBuild else { return false }
        return runningCodeHash != replacementCodeHash
    }

    /// Called only after requests have drained and recovery has finished. A
    /// rejected final image or ledger write reopens service rather than exiting.
    public static func finishHandoff(revalidateAndRecord: () -> Bool,
                                     resumeService: () -> Void, exitProcess: () -> Void) {
        guard revalidateAndRecord() else { resumeService(); return }
        exitProcess()
    }

    /// Same ordering for signal shutdown and upgrade handoff. Failed recovery
    /// exits unsuccessfully so launchd can launch the replacement's startup
    /// recovery; the recovery marker is owned by the existing fan executor.
    public static func prepareForExit(stopRequestsAndSampling: () -> Void,
                                      restoreSleep: () -> Bool, restoreFans: () -> Bool) -> Bool {
        stopRequestsAndSampling()
        let sleepRestored = restoreSleep()
        let fansRestored = restoreFans()
        return sleepRestored && fansRestored
    }
}

/// A canonical positive decimal build, read only from validated signing info.
/// Missing/ambiguous versions cannot authorize a handoff. No client supplies it.
public struct HelperSignedBuildVersion: Equatable, Comparable, Sendable {
    public let value: UInt64
    public var description: String { String(value) }
    public init?(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 20, text.utf8.first != 48,
              text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(text), value > 0 else { return nil }
        self.value = value
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}
