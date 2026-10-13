import Darwin
import Foundation

/// A response allowance is created only for an actual kernel-observed sudo
/// process inside a currently running, approved command. No blanket quota.
public final class UpdateAskpassInvocationRegistry: @unchecked Sendable {
    public static let shared = UpdateAskpassInvocationRegistry()
    private let lock = NSLock()
    private var roots = [String: Set<UpdateProcessIdentity>]()
    private var consumed = [String: Set<UpdateProcessIdentity>]()
    public init() {}
    public func begin(socket: String, root: UpdateProcessIdentity) { lock.withLock { roots[socket, default: []].insert(root) } }
    public func end(socket: String, root: UpdateProcessIdentity) { lock.withLock { roots[socket]?.remove(root) } }
    public func remove(socket: String) { lock.withLock { roots[socket] = nil; consumed[socket] = nil } }
    public func claim(socket: String, sudo: UpdateProcessIdentity, lookup: (pid_t) -> UpdateProcessSnapshot? = UpdateProcessSnapshot.read) -> Bool {
        let approved = lock.withLock { roots[socket] ?? [] }
        guard let process = lookup(sudo.pid), process.identity == sudo, process.executable == "/usr/bin/sudo" else { return false }
        var current = process; var bound: UpdateProcessIdentity?
        for _ in 0..<64 {
            if approved.contains(current.identity) { bound = current.identity; break }
            guard let parent = lookup(current.parentPID), parent.identity.pid != current.identity.pid else { break }
            current = parent
        }
        guard let bound else { return false }
        return lock.withLock {
            guard roots[socket]?.contains(bound) == true else { return false }
            return consumed[socket, default: []].insert(sudo).inserted
        }
    }
}
