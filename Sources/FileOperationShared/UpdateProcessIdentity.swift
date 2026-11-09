import Darwin
import Foundation

public struct UpdateProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    public let startTime: UInt64
    public init(pid: pid_t, startTime: UInt64) { self.pid = pid; self.startTime = startTime }
}
public struct UpdateProcessSnapshot: Sendable {
    public let identity: UpdateProcessIdentity
    public let parentPID: pid_t
    public let groupPID: pid_t
    public let uid: uid_t
    public let executable: String
    public let zombie: Bool
    public init(pid: pid_t, startTime: UInt64, parentPID: pid_t, groupPID: pid_t, uid: uid_t, executable: String, zombie: Bool = false) {
        identity = .init(pid: pid, startTime: startTime); self.parentPID = parentPID; self.groupPID = groupPID
        self.uid = uid; self.executable = executable; self.zombie = zombie
    }
    public static func read(_ pid: pid_t) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 || info.pbi_status == SZOMB else { return nil }
        let executable = String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return .init(pid: pid, startTime: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
            parentPID: pid_t(info.pbi_ppid), groupPID: pid_t(info.pbi_pgid), uid: info.pbi_uid, executable: executable, zombie: info.pbi_status == SZOMB)
    }
    public static func table() -> [Self]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 256)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0, found < pids.count else { return nil }
        return pids.prefix(Int(found)).filter { $0 > 0 }.compactMap(Self.read)
    }
}

/// D245 (review P2-5): whether an application bundle's main program runs,
/// from the process table. The file-operation helper is a root LaunchDaemon:
/// `NSRunningApplication` sees no user session's applications there and always
/// answered "none". This is the client's own check (`ApplicationTerminator
/// .isRunning`: the app's instances), repeated just before the move; a program
/// embedded elsewhere in the bundle does not count, as it does not there.
public enum RunningBundleCheck {
    /// Fails closed: an unreadable process table counts as running.
    public static func mainExecutableIsRunning(bundlePath: String, executableName: String?) -> Bool {
        guard let table = UpdateProcessSnapshot.table() else { return true }
        return mainExecutableIsRunning(bundlePath: bundlePath, executableName: executableName, processes: table)
    }

    public static func mainExecutableIsRunning(bundlePath: String, executableName: String?,
                                               processes: [UpdateProcessSnapshot]) -> Bool {
        var directory = bundlePath
        while directory.count > 1, directory.hasSuffix("/") { directory.removeLast() }
        let programs = directory + "/Contents/MacOS/"
        let live = processes.filter { !$0.zombie }
        if let name = executableName, !name.isEmpty, !name.contains("/") {
            return live.contains { $0.executable == programs + name }
        }
        // No usable CFBundleExecutable: any program directly in Contents/MacOS.
        return live.contains {
            $0.executable.hasPrefix(programs) && !$0.executable.dropFirst(programs.count).contains("/")
        }
    }
}
