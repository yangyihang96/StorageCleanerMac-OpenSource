import AgentShared
import Darwin
import FileOperationShared
import Foundation

/// The bridge's side of the private socket (D263). Connects lazily, checks
/// that the peer is its own App before sending anything, keeps one connection
/// for every call, and turns "no socket" into the reason a user can act on:
/// the switch is off, or the App is not running.
public final class AgentSocketTransport: AgentAppTransport, @unchecked Sendable {
    public static let greetingTimeout = 5
    public static let callTimeout: TimeInterval = 30

    private let socketPath: String
    private let authorizeApp: @Sendable (UpdateAskpassKernelPeer) -> Bool
    private let interfaceEnabled: @Sendable () -> Bool?
    private let lock = NSLock()
    /// Held while a connection is being set up, so concurrent first calls
    /// share one connection; `lock` stays free for the request counter.
    private let connecting = NSLock()
    private var link: AgentSocketLink?
    private var counter = 0

    /// `interfaceEnabled` reads the App's own preference; nil when unreadable.
    public init(socketPath: String, authorizeApp: @escaping @Sendable (UpdateAskpassKernelPeer) -> Bool,
                interfaceEnabled: @escaping @Sendable () -> Bool?) {
        self.socketPath = socketPath; self.authorizeApp = authorizeApp; self.interfaceEnabled = interfaceEnabled
    }

    public func call(_ request: AgentChannelRequest) async -> AgentCallResult {
        // One retry, and only when the request never left: a reused connection
        // may have died with the App, and a proposal must not be sent twice.
        for attempt in 0..<2 {
            let link: AgentSocketLink
            switch connect() {
            case .success(let connected): link = connected
            case .failure(let refusal): return .refused(refusal)
            }
            var forwarded = request
            forwarded.id = lock.withLock { counter += 1; return "b\(counter)" }
            switch await link.send(forwarded, timeout: Self.callTimeout) {
            case .response(let response):
                if let refusal = response.refusal { return .refused(refusal) }
                if let result = response.result { return .result(result) }
                return .refused(AgentRefusal(.internalError))
            case .notSent where attempt == 0:
                forget(link)
                continue
            case .notSent, .closed:
                forget(link)
                return .refused(closedRefusal())
            case .timedOut:
                return .refused(AgentRefusal(.busy, "存储清理助手没有及时回应，请稍后再试。"))
            case .cancelled:
                return .refused(AgentRefusal(.internalError, "调用已取消。"))
            }
        }
        return .refused(closedRefusal())
    }

    public func close() {
        let current = lock.withLock { defer { link = nil }; return link }
        current?.hangUp()
    }

    private func forget(_ stale: AgentSocketLink) {
        lock.withLock { if link === stale { link = nil } }
        stale.hangUp()
    }

    private func closedRefusal() -> AgentRefusal {
        interfaceEnabled() == false ? AgentRefusal(.interfaceOff) : AgentRefusal(.appNotRunning)
    }

    private func connect() -> Result<AgentSocketLink, AgentRefusal> {
        connecting.withLock {
            if let current = lock.withLock({ link }), current.isOpen { return .success(current) }
            let result = establish()
            if case .success(let connected) = result { lock.withLock { link = connected } }
            return result
        }
    }

    private func establish() -> Result<AgentSocketLink, AgentRefusal> {
        do {
            try AgentSocketLocation.checkSocket(path: socketPath)
        } catch .missing {
            return .failure(closedRefusal())
        } catch {
            // A link, a plain file or another user's socket: not our App.
            return .failure(AgentRefusal(.appUnverified))
        }
        guard var address = try? UpdateAskpassPeer.address(socketPath) else { return .failure(AgentRefusal(.internalError)) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(AgentRefusal(.internalError)) }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let failure = errno
            Darwin.close(fd)
            return .failure(failure == ECONNREFUSED || failure == ENOENT ? closedRefusal() : AgentRefusal(.internalError))
        }
        // Nothing is sent before the peer is known to be our own App.
        guard let peer = UpdateAskpassKernelPeer.read(socket: fd), authorizeApp(peer) else {
            Darwin.close(fd)
            return .failure(AgentRefusal(.appUnverified))
        }
        guard case let (greeting, leftover)? = Self.readGreeting(fd) else {
            Darwin.close(fd)
            return .failure(AgentRefusal(.internalError, "存储清理助手关闭了连接，可能是桥接程序没有通过校验。"))
        }
        guard greeting.channelVersion == AgentChannel.version else {
            Darwin.close(fd)
            return .failure(AgentRefusal(.channelVersionMismatch))
        }
        if let refusal = greeting.refusal {
            Darwin.close(fd)
            return .failure(refusal)
        }
        return .success(AgentSocketLink(fd: fd, leftover: leftover))
    }

    private static func readGreeting(_ fd: Int32) -> (AgentChannelGreeting, Data)? {
        var limit = timeval(tv_sec: greetingTimeout, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while received.count < 16 * 1024 {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            received.append(contentsOf: chunk[0..<count])
            guard let newline = received.firstIndex(of: 0x0A) else { continue }
            guard let greeting = try? AgentLineCodec.decode(AgentChannelGreeting.self, from: received[..<newline]) else { return nil }
            var none = timeval()
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
            return (greeting, Data(received[received.index(after: newline)...]))
        }
        return nil
    }
}

/// One connection to the App. Its reader thread owns the descriptor; writes
/// and the final close share a lock so nothing is written to a reused one.
final class AgentSocketLink: @unchecked Sendable {
    enum Outcome: Sendable {
        case response(AgentChannelResponse)
        /// The request never left: safe to send again on a new connection.
        case notSent
        /// Sent, then the connection ended before an answer.
        case closed
        case timedOut
        case cancelled
    }

    private let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var open = true
    private var waiting: [String: CheckedContinuation<Outcome, Never>] = [:]

    init(fd: Int32, leftover: Data) {
        self.fd = fd
        Thread { [self] in readLoop(leftover) }.start()
    }

    var isOpen: Bool { stateLock.withLock { open } }

    func send(_ request: AgentChannelRequest, timeout: TimeInterval) async -> Outcome {
        guard let line = try? AgentLineCodec.encodeLine(request) else { return .notSent }
        let id = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let registered = stateLock.withLock { () -> Bool in
                    guard open else { return false }
                    waiting[id] = continuation
                    return true
                }
                guard registered else { return continuation.resume(returning: .notSent) }
                guard write(line) else { return resolve(id, .notSent) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.resolve(id, .timedOut) }
            }
        } onCancel: {
            resolve(id, .cancelled)
        }
    }

    func hangUp() {
        writeLock.withLock { if stateLock.withLock({ open }) { _ = shutdown(fd, SHUT_RDWR) } }
    }

    private func resolve(_ id: String, _ outcome: Outcome) {
        stateLock.withLock { waiting.removeValue(forKey: id) }?.resume(returning: outcome)
    }

    private func write(_ line: Data) -> Bool {
        writeLock.withLock {
            guard stateLock.withLock({ open }) else { return false }
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

    private func readLoop(_ leftover: Data) {
        var buffer = AgentLineBuffer(maximumLineLength: AgentChannel.maximumResponseLineBytes)
        var lines = buffer.append(leftover)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        reading: while true {
            for line in lines {
                guard case .line(let data) = line, let response = try? AgentLineCodec.decode(AgentChannelResponse.self, from: data) else {
                    break reading
                }
                resolve(response.id, .response(response))
            }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { lines = []; continue }
            guard count > 0 else { break }
            lines = buffer.append(Data(chunk[0..<count]))
        }
        let pending = writeLock.withLock {
            let pending = stateLock.withLock { () -> [CheckedContinuation<Outcome, Never>] in
                open = false
                defer { waiting = [:] }
                return Array(waiting.values)
            }
            Darwin.close(fd)
            return pending
        }
        pending.forEach { $0.resume(returning: .closed) }
    }
}
