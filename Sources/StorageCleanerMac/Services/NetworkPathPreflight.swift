import Dispatch
import Foundation
import Network

enum NetworkPathWarning: String, Codable, Sendable {
    case expensive
    case constrained
}

enum NetworkPathInterface: String, Codable, Hashable, Sendable {
    case wifi
    case wired
    case cellular
    case other
}

enum NetworkPathPreflightResult: Equatable, Sendable {
    case offline
    case warning(NetworkPathWarning)
    case ready(interface: NetworkPathInterface)
}

struct NetworkPathSnapshot: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case satisfied
        case unsatisfied
    }

    let status: Status
    let isExpensive: Bool
    let isConstrained: Bool
    let interfaces: Set<NetworkPathInterface>

    init(
        status: Status,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        interfaces: Set<NetworkPathInterface>
    ) {
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interfaces = interfaces
    }
}

protocol NetworkPathSourcing: AnyObject, Sendable {
    func start(
        queue: DispatchQueue,
        updateHandler: @escaping @Sendable (NetworkPathSnapshot) -> Void
    )
    func cancel()
}

struct NetworkPathPreflight: Sendable {
    static let queueLabelPrefix = "com.local.StorageCleanerMac.network-path-preflight"

    private let sourceFactory: @Sendable () -> any NetworkPathSourcing

    init() {
        sourceFactory = { LiveNetworkPathSource() }
    }

    init(sourceFactory: @escaping @Sendable () -> any NetworkPathSourcing) {
        self.sourceFactory = sourceFactory
    }

    func probe() async throws -> NetworkPathPreflightResult {
        let source = sourceFactory()
        let queue = DispatchQueue(
            label: "\(Self.queueLabelPrefix).\(UUID().uuidString)",
            qos: .userInitiated
        )
        let coordinator = NetworkPathProbeCoordinator(source: source, queue: queue)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.installAndStart(continuation)
            }
        } onCancel: {
            coordinator.cancel()
        }
    }

    static func result(for snapshot: NetworkPathSnapshot) -> NetworkPathPreflightResult {
        guard snapshot.status == .satisfied else { return .offline }
        if snapshot.isExpensive { return .warning(.expensive) }
        if snapshot.isConstrained { return .warning(.constrained) }

        let interface: NetworkPathInterface
        if snapshot.interfaces.contains(.wifi) {
            interface = .wifi
        } else if snapshot.interfaces.contains(.wired) {
            interface = .wired
        } else if snapshot.interfaces.contains(.cellular) {
            interface = .cellular
        } else {
            interface = .other
        }
        return .ready(interface: interface)
    }
}

private final class LiveNetworkPathSource: NetworkPathSourcing, @unchecked Sendable {
    private let monitor = NWPathMonitor()

    func start(
        queue: DispatchQueue,
        updateHandler: @escaping @Sendable (NetworkPathSnapshot) -> Void
    ) {
        monitor.pathUpdateHandler = { path in
            var interfaces = Set<NetworkPathInterface>()
            if path.usesInterfaceType(.wifi) { interfaces.insert(.wifi) }
            if path.usesInterfaceType(.wiredEthernet) { interfaces.insert(.wired) }
            if path.usesInterfaceType(.cellular) { interfaces.insert(.cellular) }

            updateHandler(NetworkPathSnapshot(
                status: path.status == .satisfied ? .satisfied : .unsatisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained,
                interfaces: interfaces
            ))
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}

private final class NetworkPathProbeCoordinator: @unchecked Sendable {
    private enum State {
        case awaitingInstall
        case running
        case terminal
    }

    private let source: any NetworkPathSourcing
    private let queue: DispatchQueue
    private var continuation: CheckedContinuation<NetworkPathPreflightResult, any Error>?
    private var state = State.awaitingInstall
    private var didCancelSource = false

    init(source: any NetworkPathSourcing, queue: DispatchQueue) {
        self.source = source
        self.queue = queue
    }

    func installAndStart(
        _ continuation: CheckedContinuation<NetworkPathPreflightResult, any Error>
    ) {
        queue.async { [self] in
            guard state == .awaitingInstall else {
                continuation.resume(throwing: CancellationError())
                return
            }

            self.continuation = continuation
            state = .running
            source.start(queue: queue) { [weak self] snapshot in
                self?.receive(snapshot)
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard state != .terminal else { return }
            state = .terminal
            cancelSourceOnce()
            let continuation = takeContinuation()
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func receive(_ snapshot: NetworkPathSnapshot) {
        queue.async { [self] in
            guard state == .running else { return }
            state = .terminal
            cancelSourceOnce()
            let continuation = takeContinuation()
            continuation?.resume(returning: NetworkPathPreflight.result(for: snapshot))
        }
    }

    private func takeContinuation() -> CheckedContinuation<NetworkPathPreflightResult, any Error>? {
        let continuation = continuation
        self.continuation = nil
        return continuation
    }

    private func cancelSourceOnce() {
        guard !didCancelSource else { return }
        didCancelSource = true
        source.cancel()
    }
}
