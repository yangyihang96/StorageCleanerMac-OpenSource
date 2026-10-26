import Darwin
import Foundation

/// D188: no executable, shell, launch request or privileged process. Only
/// SIGTERM to this user's sharedfilelistd, rechecked immediately before signaling.
struct RecentItemsProcessController: Sendable {
    struct ProcessIdentity: Equatable, Sendable {
        let pid: pid_t
        let userID: uid_t
        let name: String
    }
    enum Result: Equatable, Sendable {
        case notRunning, terminated(Int), failed
    }
    let currentUserID: uid_t
    private let processes: @Sendable () throws -> [ProcessIdentity]
    private let lookup: @Sendable (pid_t) throws -> ProcessIdentity?
    private let signal: @Sendable (pid_t, Int32) -> Int32

    init(currentUserID: uid_t = getuid(),
         processes: @escaping @Sendable () throws -> [ProcessIdentity] = currentUserProcesses,
         lookup: @escaping @Sendable (pid_t) throws -> ProcessIdentity? = process,
         signal: @escaping @Sendable (pid_t, Int32) -> Int32 = Darwin.kill) {
        self.currentUserID = currentUserID
        self.processes = processes; self.lookup = lookup; self.signal = signal
    }

    static func isEligible(_ process: ProcessIdentity, userID: uid_t) -> Bool {
        process.pid > 1 && process.name == "sharedfilelistd" && process.userID == userID
    }

    func restart() -> Result {
        do {
            var terminated = 0
            var failed = false
            for candidate in try processes() where Self.isEligible(candidate, userID: currentUserID) {
                guard let current = try lookup(candidate.pid), current == candidate,
                      Self.isEligible(current, userID: currentUserID) else { continue }
                if signal(current.pid, SIGTERM) == 0 { terminated += 1 }
                else { failed = true }
            }
            return failed ? .failed : (terminated == 0 ? .notRunning : .terminated(terminated))
        } catch { return .failed }
    }

    private static func currentUserProcesses() throws -> [ProcessIdentity] {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&query, u_int(query.count), nil, &size, nil, 0) == 0 else { throw POSIXError(.EIO) }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = entries.count * MemoryLayout<kinfo_proc>.stride
        let status = entries.withUnsafeMutableBytes { sysctl(&query, u_int(query.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { throw POSIXError(.EIO) }
        return entries.prefix(size / MemoryLayout<kinfo_proc>.stride).map(describe)
    }

    private static func process(_ pid: pid_t) throws -> ProcessIdentity? {
        guard pid > 1 else { return nil }
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var entry = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&query, u_int(query.count), &entry, &size, nil, 0) == 0 else { throw POSIXError(.EIO) }
        return size == MemoryLayout<kinfo_proc>.stride ? describe(entry) : nil
    }

    private static func describe(_ entry: kinfo_proc) -> ProcessIdentity {
        let name = withUnsafeBytes(of: entry.kp_proc.p_comm) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessIdentity(pid: entry.kp_proc.p_pid, userID: entry.kp_eproc.e_ucred.cr_uid, name: name)
    }
}
