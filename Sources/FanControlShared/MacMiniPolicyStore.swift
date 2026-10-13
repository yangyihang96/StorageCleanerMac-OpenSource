import Darwin
import Foundation

private enum MacMiniArchiveError: Error, CustomStringConvertible {
    case unsafeDirectory
    case unsafeFile(String)
    case unsupportedVersion(Int)
    case legacyBindingUnavailable(MacMiniPersistedState)
    var description: String {
        switch self {
        case .unsafeDirectory: "directory owner, type or permissions rejected (requires private 0700)"
        case .unsafeFile(let name): "\(name) owner, type, links, permissions or size rejected (requires regular 0600)"
        case .unsupportedVersion(let version): "unsupported archive version \(version)"
        case .legacyBindingUnavailable: "trusted legacy recovery awaits signing identity"
        }
    }
}

public struct MacMiniPolicyLoad: Sendable {
    public let state: MacMiniPersistedState
    public let reason: String?
    public var persistenceUnavailable: Bool { reason != nil }

    public init(state: MacMiniPersistedState = .init(), reason: String? = nil) {
        self.state = state
        self.reason = reason
    }
}

public struct MacMiniPolicyRecord: Codable, Sendable {
    public let version: Int
    public let application: MacMiniApplicationIdentity
    public let state: MacMiniPersistedState

    public init(application: MacMiniApplicationIdentity, state: MacMiniPersistedState) {
        version = 2
        self.application = application
        self.state = state
    }
}

/// Only the helper supplies /var/db and uid 0. Tests must supply their owned
/// temporary directory and uid; no live location or privileged default exists.
public final class MacMiniPolicyStore {
    private let directory: Int32
    private let trustedOwner: uid_t
    private var application: MacMiniApplicationIdentity?
    private let applicationWasKnown: Bool

    public init(directoryURL: URL, application: MacMiniApplicationIdentity?, trustedOwner: uid_t) throws {
        self.application = application
        self.applicationWasKnown = application != nil
        self.trustedOwner = trustedOwner
        guard geteuid() == trustedOwner else { throw MacMiniModeFailure.persistenceFailed }
        if mkdir(directoryURL.path, 0o700) != 0, errno != EEXIST { throw MacMiniModeFailure.persistenceFailed }
        directory = try Self.openTrustedDirectory(directoryURL, owner: trustedOwner)
    }

    deinit { close(directory) }

    /// A Mac mini archive is optional service state, never a daemon startup gate.
    public static func openOrDegrade(directoryURL: URL, application: MacMiniApplicationIdentity?,
                                     trustedOwner: uid_t) -> (store: MacMiniPolicyStore?, load: MacMiniPolicyLoad) {
        do {
            let store = try MacMiniPolicyStore(directoryURL: directoryURL, application: application, trustedOwner: trustedOwner)
            return (store, store.load())
        } catch {
            return (nil, .init(reason: "unsafe or unavailable policy directory: \(error)"))
        }
    }

    public static func openTrustedDirectory(_ url: URL, owner: uid_t) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MacMiniModeFailure.persistenceFailed }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == owner,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_mode & 0o7777 == 0o700 else {
            close(descriptor)
            throw MacMiniArchiveError.unsafeDirectory
        }
        return descriptor
    }

    /// Lock-directory failure must not hide our independently protected recovery
    /// debt. Read only: never create, migrate, quarantine or change either file.
    /// The result cannot authorize enabling or infer debt from the system value.
    public static func readRecoveryWithoutLock(directoryURL: URL, trustedOwner: uid_t) -> MacMiniPolicyLoad {
        do {
            let descriptor = try openTrustedDirectory(directoryURL, owner: trustedOwner)
            defer { close(descriptor) }
            var reasons: [String] = []
            for name in ["policy.json", "recovery.json"] {
                do {
                    guard let data = try readData(directory: descriptor, name: name, owner: trustedOwner) else { continue }
                    let header = try JSONDecoder().decode(HoldingRecord.self, from: data)
                    let state: MacMiniPersistedState
                    switch header.version {
                    case 1: state = header.state // Own legacy proof, never peer occupancy or intent.
                    case 2: state = try JSONDecoder().decode(MacMiniPolicyRecord.self, from: data).state
                    default: throw MacMiniArchiveError.unsupportedVersion(header.version)
                    }
                    // A valid committed policy is authoritative, including a
                    // cleared debt whose old journal could not yet be removed.
                    return .init(state: .init(ownsSleepDisabled: state.ownsSleepDisabled),
                        reason: "shared lock unavailable; read-only trusted recovery=\(state.ownsSleepDisabled) from \(name); \(reasons.joined(separator: "; "))")
                } catch {
                    reasons.append("\(name): \(error)")
                }
            }
            return .init(reason: "shared lock unavailable; no trusted recovery proof; \(reasons.joined(separator: "; "))")
        } catch {
            return .init(reason: "shared lock unavailable; recovery directory rejected: \(error)")
        }
    }

    public func load() -> MacMiniPolicyLoad {
        do {
            if let record = try readRecord("policy.json", allowsLegacy: true) {
                // Unknown helper signing is not proof of a different installation.
                // Adopt the trusted record only for recovery writes; lifecycle
                // still requires a verified current identity before enabling.
                let same = !applicationWasKnown || record.application == application
                if application == nil { application = record.application }
                let state = record.state.boundToApplication(isSameInstallation: same)
                if state != record.state { try save(state) }
                return MacMiniPolicyLoad(state: state)
            }
            if let recovery = try readRecord("recovery.json", allowsLegacy: false), recovery.state.ownsSleepDisabled {
                if application == nil { application = recovery.application }
                return MacMiniPolicyLoad(state: .init(ownsSleepDisabled: true), reason: "intent missing; trusted recovery journal retained")
            }
            return MacMiniPolicyLoad()
        } catch {
            if let archiveError = error as? MacMiniArchiveError,
               case .legacyBindingUnavailable(let state) = archiveError {
                // This state came from the already validated private v1 file.
                // Its unprovable intent is always Off; retain recovery proof
                // in place until 0 is verified, without inventing a binding.
                NSLog("Mac mini mode legacy migration deferred: signing identity unknown; recovery retained")
                return MacMiniPolicyLoad(state: state)
            }
            // Never decode an unsafe file or infer ownership from SleepDisabled.
            // Independently protected pre-write recovery can still prove our debt.
            let recovery = try? readRecord("recovery.json", allowsLegacy: false)
            let owns = recovery?.state.ownsSleepDisabled == true
            if application == nil { application = recovery?.application }
            // renameat preserves damaged evidence without following a link.
            // Only a previously validated private directory is used here.
            let quarantine = "policy.damaged-\(UUID().uuidString).json"
            let moved = renameat(directory, "policy.json", directory, quarantine) == 0
            if moved { _ = fsync(directory) }
            return MacMiniPolicyLoad(state: .init(ownsSleepDisabled: owns),
                reason: "invalid policy (\(error)); recovery=\(owns); quarantined=\(moved)")
        }
    }

    /// Read-only sibling inspection under the shared process lock. Absence is
    /// free; unsafe/unreadable data throws and refuses an enable, never overwrites.
    public static func isHolding(directoryURL: URL, trustedOwner: uid_t,
                                 validateApplication: (MacMiniApplicationIdentity) -> Bool? = { _ in true }) throws -> Bool {
        var metadata = stat()
        if lstat(directoryURL.path, &metadata) != 0, errno == ENOENT { return false }
        let descriptor = try openTrustedDirectory(directoryURL, owner: trustedOwner)
        defer { close(descriptor) }
        for name in ["policy.json", "recovery.json"] {
            if let data = try readData(directory: descriptor, name: name, owner: trustedOwner) {
                // v1 has no verifiable installation binding and is expired as
                // a peer claim. Leave its bytes for that helper's own recovery.
                let object = try JSONDecoder().decode(HoldingRecord.self, from: data)
                guard [1, 2].contains(object.version) else { throw MacMiniArchiveError.unsupportedVersion(object.version) }
                if object.version == 1 { continue }
                if object.version == 2 {
                    let record = try JSONDecoder().decode(MacMiniPolicyRecord.self, from: data)
                    // A missing or definitely mismatched installation no longer
                    // holds the setting. Unknown verification remains reserved;
                    // do not delete or rewrite the other identity's evidence.
                    if validateApplication(record.application) == false { continue }
                }
                if object.state.requiresResidentHelper { return true }
            }
        }
        return false
    }

    public func save(_ state: MacMiniPersistedState) throws {
        if !state.requiresResidentHelper {
            // Clean Off needs no signing claim, only this trusted directory.
            // Commit removal of intent before discarding recovery evidence.
            try remove("policy.json")
            try remove("recovery.json")
            return
        }
        guard let application else { throw MacMiniModeFailure.persistenceFailed }
        let data = try JSONEncoder().encode(MacMiniPolicyRecord(application: application, state: state))
        // Separate durable proof survives a damaged intent archive. Both writes
        // finish BEFORE the engine may execute disablesleep=1.
        if state.ownsSleepDisabled { try write(data, to: "recovery.json") }
        if state.requiresResidentHelper {
            try write(data, to: "policy.json")
        } else {
            try remove("policy.json")
        }
        // First commit the disarmed policy, then discard its recovery journal.
        if !state.ownsSleepDisabled { try remove("recovery.json") }
    }

    private struct HoldingRecord: Decodable {
        let version: Int
        let state: MacMiniPersistedState
    }

    private func readRecord(_ name: String, allowsLegacy: Bool) throws -> MacMiniPolicyRecord? {
        guard let data = try Self.readData(directory: directory, name: name, owner: trustedOwner) else { return nil }
        let header = try JSONDecoder().decode(HoldingRecord.self, from: data)
        if allowsLegacy, header.version == 1 {
            // v1 cannot prove path/signature continuity. Migrate once to off;
            // preserve ONLY its trusted ownership proof, not dev/inode intent.
            let state = MacMiniPersistedState(ownsSleepDisabled: header.state.ownsSleepDisabled)
            guard let application else { throw MacMiniArchiveError.legacyBindingUnavailable(state) }
            try save(state)
            return MacMiniPolicyRecord(application: application, state: state)
        }
        guard header.version == 2 else { throw MacMiniArchiveError.unsupportedVersion(header.version) }
        return try JSONDecoder().decode(MacMiniPolicyRecord.self, from: data)
    }

    private static func readData(directory: Int32, name: String, owner: uid_t) throws -> Data? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw MacMiniModeFailure.persistenceFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == owner,
              metadata.st_nlink == 1, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & 0o7777 == 0o600, metadata.st_size > 0, metadata.st_size <= 4096,
              let data = try file.read(upToCount: 4097), data.count <= 4096 else {
            throw MacMiniArchiveError.unsafeFile(name)
        }
        return data
    }

    private func write(_ data: Data, to name: String) throws {
        let temporaryName = "policy-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MacMiniModeFailure.persistenceFailed }
        defer { unlinkat(directory, temporaryName, 0) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.synchronize()
        guard renameat(directory, temporaryName, directory, name) == 0, fsync(directory) == 0 else {
            throw MacMiniModeFailure.persistenceFailed
        }
    }

    private func remove(_ name: String) throws {
        if unlinkat(directory, name, 0) != 0, errno != ENOENT { throw MacMiniModeFailure.persistenceFailed }
        guard fsync(directory) == 0 else { throw MacMiniModeFailure.persistenceFailed }
    }
}

/// Both build identities use the SAME private directory and lock inode.
public final class MacMiniPolicyLock {
    private let descriptor: Int32

    public init(directoryURL: URL, trustedOwner: uid_t) throws {
        guard geteuid() == trustedOwner else { throw MacMiniModeFailure.persistenceFailed }
        if mkdir(directoryURL.path, 0o700) != 0, errno != EEXIST { throw MacMiniModeFailure.persistenceFailed }
        let directory = try MacMiniPolicyStore.openTrustedDirectory(directoryURL, owner: trustedOwner)
        defer { close(directory) }
        let file = openat(directory, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard file >= 0 else { throw MacMiniModeFailure.persistenceFailed }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_uid == trustedOwner, metadata.st_nlink == 1,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_mode & 0o7777 == 0o600 else {
            close(file)
            throw MacMiniModeFailure.persistenceFailed
        }
        descriptor = file
    }

    deinit { close(descriptor) }
    public func acquire(pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Bool {
        MacMiniLockRetry.acquire(tryAcquire: { flock(descriptor, LOCK_EX | LOCK_NB) == 0 }, pause: pause)
    }
    public func release() { _ = flock(descriptor, LOCK_UN) }
}
