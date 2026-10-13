import Darwin
import Foundation
import Security

/// Never Codable, printable, or part of a command/environment. The sole owned
/// byte buffer is locked and explicitly erased on every exit path.
public final class UpdatePasswordBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: UnsafeMutableRawPointer
    private var count: Int
    public init(bytes: [UInt8]) {
        count = bytes.count
        storage = .allocate(byteCount: max(1, count), alignment: 1)
        bytes.withUnsafeBytes { if let base = $0.baseAddress { storage.copyMemory(from: base, byteCount: count) } }
    }
    public var isCleared: Bool { lock.withLock { count == 0 } }
    public func withBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try lock.withLock { try body(.init(start: storage, count: count)) }
    }
    public func clear() { lock.withLock { _ = memset_s(storage, max(1, count), 0, max(1, count)); count = 0 } }
    deinit { clear(); storage.deallocate() }
}

public enum UpdateAskpassPeer {
    public static func processID(socket fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }
    public static func descendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<64 {
            if current == ancestor { return pid != ancestor }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
            let parent = info.kp_eproc.e_ppid
            guard parent > 1, parent != current else { return false }
            current = parent
        }
        return false
    }
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (index, value) in path.utf8.enumerated() { bytes[index] = value }
        }
        return address
    }
}

/// The channel contains no secret files. Each accepted socket is consumed once,
/// and only a kernel-bound signed askpass with a sudo parent receives bytes.
public final class UpdateAskpassChannel: @unchecked Sendable {
    public let directory: URL
    public let socketPath: String
    private let password: UpdatePasswordBuffer
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private let answerLimit: Int?
    private let authorizePeer: @Sendable (UpdateAskpassKernelPeer) -> Bool
    private let authorizeRequest: @Sendable (String, UpdateProcessIdentity) -> Bool
    private let done = DispatchGroup()
    public init(password: UpdatePasswordBuffer, maximumResponses: Int? = nil, authorizePeer: @escaping @Sendable (UpdateAskpassKernelPeer) -> Bool,
        authorizeRequest: @escaping @Sendable (String, UpdateProcessIdentity) -> Bool = { UpdateAskpassInvocationRegistry.shared.claim(socket: $0, sudo: $1) }) throws {
        self.password = password; self.answerLimit = maximumResponses; self.authorizePeer = authorizePeer; self.authorizeRequest = authorizeRequest
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("sc-ap-" + UUID().uuidString)
        socketPath = directory.appendingPathComponent("p").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { try? FileManager.default.removeItem(at: directory); throw POSIXError(.EIO) }
        do {
            var address = try UpdateAskpassPeer.address(socketPath)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(listener, 4) == 0, chmod(socketPath, 0o600) == 0 else { throw POSIXError(.EACCES) }
            _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        } catch { close(listener); try? FileManager.default.removeItem(at: directory); throw error }
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in serve(); done.leave() }
    }
    private func serve() {
        var answered = Set<UpdateProcessIdentity>(); var sudoRequests = Set<UpdateProcessIdentity>()
        while !lock.withLock({ stopped }) {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            defer { close(client) }
            // Accepted sockets inherit the listener's O_NONBLOCK on Darwin; the
            // challenge exchange relies on the bounded blocking timeouts below.
            let flags = fcntl(client, F_GETFL)
            guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else { continue }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            guard let peer = UpdateAskpassKernelPeer.read(socket: client), authorizePeer(peer),
                let caller = UpdateProcessSnapshot.read(peer.pid), let parent = UpdateProcessSnapshot.read(caller.parentPID),
                !answered.contains(caller.identity), !sudoRequests.contains(parent.identity),
                answerLimit.map({ answered.count < $0 }) ?? true else { continue }
            // Each authenticated sudo request consumes a fresh one-use challenge.
            // The challenge is not a credential and never enters argv/environment.
            var token = [UInt8](repeating: 0, count: 32); var echoed = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, token.count, &token) == errSecSuccess,
                token.withUnsafeBytes({ Darwin.write(client, $0.baseAddress, $0.count) }) == token.count else { continue }
            var received = 0
            while received < echoed.count {
                let count = echoed.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress!.advanced(by: received), $0.count - received) }
                if count <= 0 { break }; received += count
            }
            guard received == token.count, echoed == token, authorizePeer(peer),
                UpdateProcessSnapshot.read(peer.pid)?.identity == caller.identity,
                UpdateProcessSnapshot.read(parent.identity.pid)?.identity == parent.identity,
                authorizeRequest(socketPath, parent.identity) else { continue }
            answered.insert(caller.identity); sudoRequests.insert(parent.identity)
            password.withBytes { bytes in
                guard !bytes.isEmpty, let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(client, base.advanced(by: offset), bytes.count - offset)
                    guard n > 0 else { return }
                    offset += n
                }
                var newline: UInt8 = 10
                _ = Darwin.write(client, &newline, 1)
            }
        }
    }
    public func finish() {
        let first = lock.withLock { if stopped { return false }; stopped = true; return true }
        guard first else { return }
        password.clear()
        UpdateAskpassInvocationRegistry.shared.remove(socket: socketPath)
        _ = done.wait(timeout: .now() + 3)
        close(listener)
        try? FileManager.default.removeItem(at: directory)
    }
}
