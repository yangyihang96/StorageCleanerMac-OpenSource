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
