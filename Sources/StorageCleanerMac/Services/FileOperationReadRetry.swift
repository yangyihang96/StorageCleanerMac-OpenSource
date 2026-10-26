import Foundation

/// A transport failure means that no reply was received, not that the helper
/// rejected an operation. Mutations must never replay after an unknown outcome.
enum FileOperationReadRetry {
    enum TransportFailure: Error { case noReply }

    static func perform<Value>(isolation: isolated (any Actor)? = #isolation,
        readOnly: Bool = true,
        wait: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        exchange: () async throws -> Value) async throws -> Value {
        do { return try await exchange() }
        catch {
            guard readOnly, isTransportFailure(error) else { throw error }
            try Task.checkCancellation()
            try await wait()
            try Task.checkCancellation()
            // The caller creates a fresh connection on every attempt. Exactly
            // one retry; decoding, build mismatch and helper errors do not retry.
            return try await exchange()
        }
    }

    private static func isTransportFailure(_ error: any Error) -> Bool {
        if error is TransportFailure { return true }
        if case .connectionLost? = error as? AuthorizedMoveError { return true }
        return false
    }
}
