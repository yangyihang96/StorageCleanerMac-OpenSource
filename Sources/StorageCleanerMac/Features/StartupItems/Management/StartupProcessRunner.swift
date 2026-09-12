import Foundation

extension StartupItemsDomain {
    struct StartupProcessResult: Equatable, Sendable {
        let standardOutput: String
        let standardError: String
        let terminationStatus: Int32

        var combinedOutput: String {
            [standardOutput, standardError]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    protocol StartupProcessRunning: Sendable {
        func run(
            executableURL: URL,
            arguments: [String],
            timeout: TimeInterval
        ) async throws -> StartupProcessResult
    }

    struct CancellableStartupProcessRunner: StartupProcessRunning {
        private let outputByteLimit: Int
        private let cleanupReaper: ShellProcessCleanupReaper

        init(
            outputByteLimit: Int = 2 * 1_024 * 1_024,
            cleanupReaper: ShellProcessCleanupReaper = .shared
        ) {
            self.outputByteLimit = outputByteLimit
            self.cleanupReaper = cleanupReaper
        }

        func run(
            executableURL: URL,
            arguments: [String],
            timeout: TimeInterval
        ) async throws -> StartupProcessResult {
            let cancellation = StartupProcessCancellationSignal()
            do {
                return try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await Task.detached(priority: .userInitiated) {
                        let result = try Shell.run(
                            executableURL.path,
                            arguments,
                            timeout: timeout,
                            outputByteLimit: outputByteLimit,
                            cancellationCheck: { cancellation.isCancelled },
                            cleanupReaper: cleanupReaper,
                            cleanupWaitTimeout: 1
                        )
                        return StartupProcessResult(
                            standardOutput: result.standardOutput,
                            standardError: result.standardError,
                            terminationStatus: result.terminationStatus
                        )
                    }.value
                } onCancel: {
                    cancellation.cancel()
                }
            } catch let error as ShellError {
                if case .cancelled = error {
                    throw CancellationError()
                }
                throw error
            }
        }
    }

    private final class StartupProcessCancellationSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }
}
