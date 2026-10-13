import Darwin
import FileOperationShared
import Foundation

/// Process identities, rather than groups, own every signal. The process table
/// follows setsid/setpgid; a recorded child remains owned after reparenting.
struct AppUpdateCommandProcessTree {
    let root: UpdateProcessIdentity
    private(set) var identities: Set<UpdateProcessIdentity>
    private(set) var trackingComplete = true
    init(root: UpdateProcessIdentity) { self.root = root; identities = [root] }
    mutating func observe(_ table: [UpdateProcessSnapshot]) {
        identities = Self.includingDescendants(of: identities, in: table)
    }
    static func includingDescendants(of recorded: Set<UpdateProcessIdentity>, in table: [UpdateProcessSnapshot]) -> Set<UpdateProcessIdentity> {
        var identities = recorded
        var changed = true
        while changed {
            changed = false
            for process in table where !identities.contains(process.identity) {
                guard table.contains(where: { $0.identity.pid == process.parentPID && identities.contains($0.identity) }) else { continue }
                identities.insert(process.identity); changed = true
            }
        }
        return identities
    }
    mutating func recordKernelChild(_ child: UpdateProcessSnapshot) { identities.insert(child.identity) }
    mutating func lostTracking() { trackingComplete = false }
    func signalTargets(current: [UpdateProcessSnapshot]) -> [UpdateProcessIdentity] {
        current.filter { identities.contains($0.identity) && !$0.zombie }.map(\.identity)
    }
    func confirmedStopped(current: [UpdateProcessSnapshot], readable: Bool = true) -> Bool {
        trackingComplete && readable && signalTargets(current: current).isEmpty
    }
}

protocol AppUpdateCommandTreeObserving {
    func observeRunning()
    func confirmedStopped() -> Bool
    func observedProcessesStopped() -> Bool
    func signal(_ signal: Int32)
    func completionEvidence() -> AppUpdateCommandCompletionEvidence
}

extension AppUpdateCommandTreeObserving {
    func completionEvidence() -> AppUpdateCommandCompletionEvidence {
        .init(trackingComplete: confirmedStopped(), knownProcessesAlive: !observedProcessesStopped(), processes: [])
    }
}

final class NativeAppUpdateCommandTree: AppUpdateCommandTreeObserving {
    private let queue: Int32
    private var tree: AppUpdateCommandProcessTree
    private var exited = Set<pid_t>()
    private var watched = Set<UpdateProcessIdentity>()
    init(root: pid_t) throws {
        guard let snapshot = UpdateProcessSnapshot.read(root) else { throw POSIXError(.ESRCH) }
        tree = .init(root: snapshot.identity)
        queue = kqueue()
        guard queue >= 0 else { throw POSIXError(.EIO) }
        guard watch(snapshot.identity) else { close(queue); throw POSIXError(.EIO) }
    }
    deinit { close(queue) }
    private func watch(_ identity: UpdateProcessIdentity) -> Bool {
        var change = kevent64_s(ident: UInt64(identity.pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: UInt32(NOTE_FORK) | NOTE_EXIT | UInt32(NOTE_EXEC), data: 0, udata: 0, ext: (0, 0))
        guard kevent64(queue, &change, 1, nil, 0, 0, nil) == 0 else { return false }
        watched.insert(identity); return true
    }
    func observeRunning() {
        guard let table = UpdateProcessSnapshot.table() else { tree.lostTracking(); return }
        tree.observe(table)
        for identity in tree.identities.subtracting(watched) {
            if !watch(identity), table.contains(where: { $0.identity == identity && !$0.zombie }) { tree.lostTracking() }
        }
        var events = [kevent64_s](repeating: .init(), count: 256)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        while true {
            let count = kevent64(queue, nil, 0, &events, Int32(events.count), 0, &timeout)
            if count < 0 { tree.lostTracking(); break }
            if count == 0 { break }
            for event in events.prefix(Int(count)) {
                let pid = pid_t(event.ident)
                if event.flags & UInt16(EV_ERROR) != 0 { tree.lostTracking() }
                // macOS explicitly does not support NOTE_TRACK/NOTE_CHILD.
                // NOTE_FORK has no child PID and may coalesce. Polling records
                // visible descendants, but cannot prove no short-lived parent
                // escaped between snapshots. Never turn that gap into a stop
                // receipt: a forked command requires trusted completion readback.
                if event.fflags & UInt32(NOTE_FORK) != 0 { tree.lostTracking() }
                if event.fflags & UInt32(NOTE_EXIT) != 0 { exited.insert(pid) }
            }
        }
    }
    private func current() -> (table: [UpdateProcessSnapshot], readable: Bool) {
        observeRunning()
        var table = [UpdateProcessSnapshot](); var readable = true
        for identity in tree.identities {
            if let value = UpdateProcessSnapshot.read(identity.pid) {
                // A reused PID proves the original is gone; it is never signalled.
                if value.identity == identity { table.append(value) }
            } else if !exited.contains(identity.pid), !(kill(identity.pid, 0) == -1 && errno == ESRCH) { readable = false }
        }
        return (table, readable)
    }
    func confirmedStopped() -> Bool {
        let state = current()
        return tree.confirmedStopped(current: state.table, readable: state.readable)
    }
    func observedProcessesStopped() -> Bool {
        let state = current()
        return state.readable && tree.signalTargets(current: state.table).isEmpty
    }
    func completionEvidence() -> AppUpdateCommandCompletionEvidence {
        let state = current()
        return .init(trackingComplete: tree.trackingComplete && state.readable,
            knownProcessesAlive: !state.readable || !tree.signalTargets(current: state.table).isEmpty,
            processes: tree.identities.map(AppUpdateTrackedProcess.init).sorted { $0.pid < $1.pid })
    }
    func signal(_ signal: Int32) {
        let state = current()
        for identity in tree.signalTargets(current: state.table) {
            guard UpdateProcessSnapshot.read(identity.pid)?.identity == identity else { continue }
            _ = kill(identity.pid, signal)
        }
    }
}
