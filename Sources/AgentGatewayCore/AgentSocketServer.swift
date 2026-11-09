import AgentShared
import Darwin
import FileOperationShared
import Foundation

/// D263: `<data directory>/Agent`, created 0700 when missing. Nothing is
/// created for a socket path that cannot work.
public enum AgentSocketDirectory {
    public static func prepare(dataDirectory: URL, uid: uid_t = getuid()) throws(AgentSocketLocationError) -> String {
        let path = AgentSocketLocation.socketPath(dataDirectory: dataDirectory)
        try AgentSocketLocation.validateLength(path)
        if mkdir(AgentSocketLocation.directory(dataDirectory: dataDirectory).path, 0o700) != 0, errno != EEXIST {
            throw .missing
        }
        try AgentSocketLocation.checkDirectory(dataDirectory: dataDirectory, uid: uid)
        return path
    }
}

/// The App's listener (D263). A connection is served only after the kernel's
/// peer facts pass `authorizePeer` (the bundled bridge, AgentBridgePeerPolicy)
/// and the client behind it is named; then one greeting line, then requests.
/// The listener wakes only when someone connects: the gateway stays resident
/// while the switch is on, so it must cost nothing when idle (D267). Blocking
/// connection threads, and `stop()` leaves nothing behind.
public final class AgentSocketServer: @unchecked Sendable {
    public static let maximumConnections = 16

    public let socketPath: String
    private let listener: Int32
    private let socketInode: ino_t
    private let authorizePeer: @Sendable (UpdateAskpassKernelPeer) -> Bool
    private let identifyClient: @Sendable (UpdateAskpassKernelPeer) -> AgentClientIdentity?
    private let handle: @Sendable (AgentChannelRequest, AgentClientIdentity) async -> AgentChannelResponse
    private let lock = NSLock()
    private var stopped = false
    private var connections: [ObjectIdentifier: AgentServedConnection] = [:]
    private var listening: (any DispatchSourceRead)?
    private let accepting = DispatchGroup()
    private let serving = DispatchGroup()

    public init(socketPath: String, authorizePeer: @escaping @Sendable (UpdateAskpassKernelPeer) -> Bool,
                identifyClient: @escaping @Sendable (UpdateAskpassKernelPeer) -> AgentClientIdentity?,
                handle: @escaping @Sendable (AgentChannelRequest, AgentClientIdentity) async -> AgentChannelResponse) throws {
        try Self.removeStaleSocket(at: socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var status = stat()
        do {
            var address = try UpdateAskpassPeer.address(socketPath)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard chmod(socketPath, 0o600) == 0, lstat(socketPath, &status) == 0, listen(fd, 16) == 0 else {
                unlink(socketPath)
                throw POSIXError(.EACCES)
            }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        } catch {
            close(fd)
            throw error
        }
        self.socketPath = socketPath; listener = fd; socketInode = status.st_ino
        self.authorizePeer = authorizePeer; self.identifyClient = identifyClient; self.handle = handle
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "agent-gateway.accept", qos: .utility))
        source.setEventHandler { [self] in acceptPending() }
        // The listener closes only once no handler can still be using it.
        accepting.enter()
        source.setCancelHandler { [accepting] in
            close(fd)
            accepting.leave()
        }
        listening = source
        source.resume()
    }

    public var connectionCount: Int { lock.withLock { connections.count } }

    /// Closes the listener, removes the socket and hangs up every connection
    /// (D265: turning the switch off disconnects at once).
    public func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        listening?.cancel()
        _ = accepting.wait(timeout: .now() + 2)
        var status = stat()
        // Only our own socket: never a file someone put there afterwards.
        if lstat(socketPath, &status) == 0, status.st_ino == socketInode, status.st_mode & S_IFMT == S_IFSOCK { unlink(socketPath) }
        lock.withLock { Array(connections.values) }.forEach { $0.hangUp() }
        _ = serving.wait(timeout: .now() + 2)
    }

    /// A socket left by a crash is replaced; a live one, or anything that is
    /// not this user's socket, is left alone.
    private static func removeStaleSocket(at path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else { return }
        guard status.st_mode & S_IFMT == S_IFSOCK, status.st_uid == getuid() else { throw POSIXError(.EEXIST) }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(probe) }
        var address = try UpdateAskpassPeer.address(path)
        let live = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        guard !live else { throw POSIXError(.EADDRINUSE) }
        guard unlink(path) == 0 else { throw POSIXError(.EACCES) }
    }

    private func acceptPending() {
        // Non-blocking: take everyone waiting, then go back to sleep.
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            let connection = AgentServedConnection(fd: fd)
            let admitted = lock.withLock { () -> Bool in
                guard !stopped, connections.count < Self.maximumConnections else { return false }
                connections[ObjectIdentifier(connection)] = connection
                return true
            }
            guard admitted else { connection.finish(); continue }
            serving.enter()
            Thread { [self] in
                serve(connection)
                lock.withLock { connections[ObjectIdentifier(connection)] = nil }
                connection.finish()
                serving.leave()
            }.start()
        }
    }

    private func serve(_ connection: AgentServedConnection) {
        // Accepted sockets inherit the listener's O_NONBLOCK on Darwin.
        let flags = fcntl(connection.fd, F_GETFL)
        guard flags >= 0, fcntl(connection.fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return }
        var noSignal: Int32 = 1
        _ = setsockopt(connection.fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(connection.fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // An unverified peer gets no byte at all.
        guard let peer = UpdateAskpassKernelPeer.read(socket: connection.fd), authorizePeer(peer) else { return }
        guard let client = identifyClient(peer) else {
            connection.send(AgentChannelGreeting(refusal: AgentRefusal(.clientUnidentified)))
            return
        }
        guard connection.send(AgentChannelGreeting(client: client.displayName)) else { return }

        var buffer = AgentLineBuffer(maximumLineLength: AgentChannel.maximumRequestLineBytes)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(connection.fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            for line in buffer.append(Data(chunk[0..<count])) {
                // Anything but a well-formed request is a broken peer: hang up.
                guard case .line(let data) = line, let request = try? AgentLineCodec.decode(AgentChannelRequest.self, from: data) else {
                    return
                }
                guard connection.begin() else {
                    connection.send(AgentChannelResponse.refused(request.id, AgentRefusal(.busy)))
                    continue
                }
                let handle = handle
                Task {
                    let response = await handle(request, client)
                    connection.end()
                    connection.answer(response)
                }
            }
        }
    }
}

/// One accepted socket. The serving thread owns the descriptor and closes it;
/// writes and the final close are serialised so a late answer never reaches
/// a reused descriptor. `state` is never held across a write: hanging up must
/// not wait for a client that stopped reading, and it is what wakes that write.
final class AgentServedConnection: @unchecked Sendable {
    let fd: Int32
    private let writing = NSLock()
    private let state = NSLock()
    private var closed = false
    private var inFlight = 0

    init(fd: Int32) { self.fd = fd }

    @discardableResult
    func send<Message: Encodable>(_ message: Message) -> Bool {
        guard let line = try? AgentLineCodec.encodeLine(message) else { return false }
        return send(line: line)
    }

    /// An answer longer than the bridge accepts would end the connection for
    /// every other call on it; it becomes a refusal instead (D266).
    func answer(_ response: AgentChannelResponse) {
        guard let line = try? AgentLineCodec.encodeLine(response), line.count <= AgentChannel.maximumResponseLineBytes else {
            send(AgentChannelResponse.refused(response.id, AgentRefusal(.internalError, "结果太大，无法传回。请减小 limit 或缩小范围。")))
            return
        }
        send(line: line)
    }

    @discardableResult
    private func send(line: Data) -> Bool {
        writing.withLock {
            guard !state.withLock({ closed }) else { return false }
            return line.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
        }
    }

    func begin() -> Bool {
        state.withLock {
            guard inFlight < AgentChannel.maximumRequestsInFlight else { return false }
            inFlight += 1
            return true
        }
    }

    func end() { state.withLock { inFlight -= 1 } }

    /// Wakes the serving thread's blocking read; it then finishes.
    func hangUp() { state.withLock { if !closed { _ = shutdown(fd, SHUT_RDWR) } } }

    func finish() {
        writing.withLock {
            state.withLock {
                guard !closed else { return }
                closed = true
                close(fd)
            }
        }
    }
}
