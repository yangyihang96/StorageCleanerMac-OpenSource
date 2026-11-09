import AgentShared
import Darwin
import FileOperationShared
import Foundation

public enum AgentGatewayFailure: Error, Equatable, Sendable {
    /// `<data>/Agent/s` cannot be used; Settings says why (D263).
    case location(AgentSocketLocationError)
    /// The App or its bundled bridge has no signature to compare a peer with.
    case bridgeUnverifiable
    /// The listener could not start; `EADDRINUSE` means another copy is live.
    case socket(Int32)
}

public enum AgentGatewayStatus: Equatable, Sendable {
    case off
    case listening
    case failed(AgentGatewayFailure)
}

/// D263: the peer policy for this App's own bundle, or nil when either end has
/// no valid signature. Takes as long as validating the bundle (about 0.2 s).
public enum AgentGatewayPolicy {
    public static let bridgeRelativePath = "Contents/Helpers/storage-cleaner-agent"

    public static func bridgePolicy(applicationURL: URL,
                                    identity: (URL) -> UpdateAskpassCodeIdentity? = UpdateAskpassCodeIdentity.file) -> AgentBridgePeerPolicy? {
        let application = URL(fileURLWithPath: AgentPaths.real(applicationURL), isDirectory: true)
        let bridge = application.appendingPathComponent(bridgeRelativePath, isDirectory: false)
        guard let own = identity(application), let bundled = identity(bridge) else { return nil }
        return .init(bridgeExecutable: bridge.path, application: own, bundledBridge: bundled)
    }
}

/// The App's AI assistant gateway: off until the user turns it on (D265), and
/// independent of any window (D267). The App supplies who may connect and the
/// answers to reads; everything else is here.
public actor AgentGateway {
    public struct Configuration: Sendable {
        public var dataDirectory: URL
        /// Asked each time the switch goes on; slow, so never on the main thread.
        public var peerAuthorization: @Sendable () -> (@Sendable (UpdateAskpassKernelPeer) -> Bool)?
        public var identifyClient: @Sendable (UpdateAskpassKernelPeer) -> AgentClientIdentity?
        public var clientStorage: AgentClientStorage
        public var provider: any AgentReadProvider
        public var onApprovalNeeded: @Sendable (AgentClientIdentity) -> Void
        public var clock: @Sendable () -> Date

        public init(dataDirectory: URL, peerAuthorization: @escaping @Sendable () -> (@Sendable (UpdateAskpassKernelPeer) -> Bool)?,
                    identifyClient: @escaping @Sendable (UpdateAskpassKernelPeer) -> AgentClientIdentity?,
                    clientStorage: AgentClientStorage, provider: any AgentReadProvider,
                    onApprovalNeeded: @escaping @Sendable (AgentClientIdentity) -> Void,
                    clock: @escaping @Sendable () -> Date = { Date() }) {
            self.dataDirectory = dataDirectory; self.peerAuthorization = peerAuthorization; self.identifyClient = identifyClient
            self.clientStorage = clientStorage; self.provider = provider; self.onApprovalNeeded = onApprovalNeeded; self.clock = clock
        }
    }

    public nonisolated let registry: AgentClientRegistry
    public nonisolated let queue = AgentRequestQueue()
    public private(set) var status = AgentGatewayStatus.off

    private let configuration: Configuration
    private nonisolated let enabled = AgentLockedBox(false)
    private nonisolated let server = AgentLockedBox<AgentSocketServer?>(nil)
    private var router: AgentGatewayRouter?
    private var log: AgentAccessLog?
    private var lastChange: Task<Void, Never>?

    public init(_ configuration: Configuration) {
        self.configuration = configuration
        registry = AgentClientRegistry(storage: configuration.clientStorage)
    }

    public var connectionCount: Int { server.value?.connectionCount ?? 0 }

    /// Stays readable in Settings while the switch is off.
    public var accessLog: AgentAccessLog {
        if let log { return log }
        let created = AgentAccessLog(fileURL: AgentSocketLocation.directory(dataDirectory: configuration.dataDirectory)
            .appendingPathComponent("access.jsonl", isDirectory: false), clock: configuration.clock)
        log = created
        return created
    }

    /// Changes run one at a time, in the order they were asked for, so quick
    /// toggling cannot leave a listener behind.
    public func setEnabled(_ on: Bool) async {
        let previous = lastChange
        let change = Task {
            await previous?.value
            await apply(on)
        }
        lastChange = change
        await change.value
    }

    /// `willTerminate` (D267): synchronous, because the process is about to
    /// end. A socket left by a crash instead is replaced on the next start.
    public nonisolated func terminate() {
        enabled.value = false
        queue.voidAll(at: configuration.clock())
        server.value?.stop()
    }

    private func apply(_ on: Bool) async {
        if on {
            guard server.value == nil else { return }
            let router = router ?? AgentGatewayRouter(isEnabled: { [enabled] in enabled.value }, registry: registry, accessLog: accessLog,
                                                      provider: configuration.provider, queue: queue,
                                                      onApprovalNeeded: configuration.onApprovalNeeded, clock: configuration.clock)
            self.router = router
            enabled.value = true
            let configuration = configuration
            let started = await Self.offThread { Self.start(configuration, router) }
            switch started {
            case .success(let running):
                server.value = running
                status = .listening
            case .failure(let failure):
                enabled.value = false
                status = .failed(failure)
            }
        } else {
            // In this order: a call racing the switch is refused, then the
            // requests go, then the socket (D265).
            enabled.value = false
            queue.voidAll(at: configuration.clock())
            if let running = server.value {
                server.value = nil
                await Self.offThread { running.stop() }
            }
            status = .off
        }
    }

    private static func start(_ configuration: Configuration, _ router: AgentGatewayRouter) -> Result<AgentSocketServer, AgentGatewayFailure> {
        let path: String
        do {
            path = try AgentSocketDirectory.prepare(dataDirectory: configuration.dataDirectory)
        } catch {
            return .failure(.location(error))
        }
        guard let authorize = configuration.peerAuthorization() else { return .failure(.bridgeUnverifiable) }
        do {
            return .success(try AgentSocketServer(socketPath: path, authorizePeer: authorize, identifyClient: configuration.identifyClient,
                                                  handle: { await router.handle($0, from: $1) }))
        } catch let error as POSIXError {
            return .failure(.socket(error.code.rawValue))
        } catch {
            return .failure(.socket(EIO))
        }
    }

    /// Signature checks and thread joins do not belong on the concurrency pool.
    private static func offThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }
}
