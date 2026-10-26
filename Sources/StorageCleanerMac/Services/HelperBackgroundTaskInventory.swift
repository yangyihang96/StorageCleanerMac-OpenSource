import FileOperationShared
import Foundation

/// D177: reads the login-item and background-task list through the
/// privileged file-operation helper, which runs `sfltool dumpbtm` as root
/// without a dialog and keeps only this user's and the system-wide records.
/// This never installs, approves or refreshes the helper: launchd starts a
/// registered one on demand; when none is registered, or it is another build
/// that may not know the request, the read fails quietly and the startup page
/// keeps its Full Scan.
struct HelperBackgroundTaskInventory: BackgroundTaskInventoryReading {
    var timeout: TimeInterval = 20

    func dump(context: StartupScanContext) async throws -> String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !build.isEmpty,
              Bundle.main.url(forResource: "StorageCleanerFileOperationHelper", withExtension: nil) != nil else {
            throw BackgroundTaskManagementScanError.helperUnavailable
        }
        do {
            return try await FileOperationReadRetry.perform {
                try await readInventory(build: build)
            }
        } catch is FileOperationReadRetry.TransportFailure {
            throw BackgroundTaskManagementScanError.helperUnavailable
        }
    }

    private func readInventory(build: String) async throws -> String {
        guard let requirement = FileOperationPeerRequirement.currentSigner(peerIdentifier: FileOperationIdentity.helper) else {
            throw BackgroundTaskManagementScanError.helperUnavailable
        }
        let connection = NSXPCConnection(machServiceName: FileOperationIdentity.helper, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FileOperationHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        // Only a helper of this very build knows the request.
        let probe = try await Self.exchange(connection, timeout: 2) { proxy, reply in
            proxy.applicationReplacementCapabilities?(reply: reply)
        }
        guard (try? JSONDecoder().decode(ApplicationReplacementCapabilities.self, from: probe))?.build == build else {
            throw BackgroundTaskManagementScanError.helperUnavailable
        }
        let data = try await Self.exchange(connection, timeout: timeout) { proxy, reply in
            proxy.backgroundTaskInventory?(reply: reply)
        }
        let reply = try JSONDecoder().decode(BackgroundTaskInventoryReply.self, from: data)
        guard let output = reply.output else {
            throw BackgroundTaskManagementScanError.restricted(reply.failure?.rawValue ?? "no output")
        }
        return output
    }

    private static func exchange(
        _ connection: NSXPCConnection,
        timeout: TimeInterval,
        _ send: (any FileOperationHelperProtocol, @escaping @Sendable (Data) -> Void) -> Void
    ) async throws -> Data {
        let gate = HelperInventoryReplyGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                connection.invalidationHandler = { @Sendable in gate.fail() }
                connection.interruptionHandler = { @Sendable in gate.fail() }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in gate.fail() })
                    as? any FileOperationHelperProtocol else { gate.fail(); return }
                send(proxy) { gate.complete($0) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { gate.fail() }
            }
        } onCancel: {
            gate.cancel()
        }
    }
}

/// One reply, a failure or the timeout, whichever comes first; cancellation
/// that arrives before the request is sent still ends it.
private final class HelperInventoryReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var cancelled = false

    func install(_ continuation: CheckedContinuation<Data, any Error>) {
        let cancelledEarly = lock.withLock { () -> Bool in
            if cancelled { return true }
            self.continuation = continuation
            return false
        }
        if cancelledEarly { continuation.resume(throwing: CancellationError()) }
    }
    func complete(_ data: Data) { take()?.resume(returning: data) }
    func fail() { take()?.resume(throwing: FileOperationReadRetry.TransportFailure.noReply) }
    func cancel() {
        let current = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            cancelled = true
            defer { continuation = nil }
            return continuation
        }
        current?.resume(throwing: CancellationError())
    }
    private func take() -> CheckedContinuation<Data, any Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
