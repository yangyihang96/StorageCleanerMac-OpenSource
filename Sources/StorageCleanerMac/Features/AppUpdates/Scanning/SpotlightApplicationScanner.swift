import Foundation

struct SpotlightApplicationScanner: Sendable {
    func scan(timeout: Duration) async throws -> SpotlightApplicationScanResult {
        let session = await MainActor.run { SpotlightApplicationQuerySession() }
        return try await session.scan(timeout: timeout)
    }
}

@MainActor
private final class SpotlightApplicationQuerySession: NSObject {
    private var query: NSMetadataQuery?
    private var continuation: CheckedContinuation<SpotlightApplicationScanResult, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    func scan(timeout: Duration) async throws -> SpotlightApplicationScanResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func start(
        continuation: CheckedContinuation<SpotlightApplicationScanResult, Error>,
        timeout: Duration
    ) {
        guard self.continuation == nil else {
            continuation.resume(throwing: ApplicationScanningError.spotlightUnavailable)
            return
        }

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "%K == %@",
            NSMetadataItemContentTypeKey,
            "com.apple.application-bundle"
        )
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinishGathering(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        self.query = query
        self.continuation = continuation
        guard query.start() else {
            finish(completion: .unavailable)
            return
        }

        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.finish(completion: .timedOut)
        }
    }

    @objc private func queryDidFinishGathering(_ notification: Notification) {
        finish(completion: .completed)
    }

    private func cancel() {
        guard !didFinish else { return }
        didFinish = true
        cleanup()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    private func finish(completion: SpotlightScanCompletion) {
        guard !didFinish else { return }
        didFinish = true
        let urls = collectedApplicationURLs()
        cleanup()
        continuation?.resume(
            returning: SpotlightApplicationScanResult(
                applicationURLs: urls,
                completion: completion
            )
        )
        continuation = nil
    }

    private func collectedApplicationURLs() -> [URL] {
        guard let query else { return [] }
        query.disableUpdates()
        var byPath = [String: URL]()
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else {
                continue
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                continue
            }
            byPath[ApplicationPathNormalizer.comparisonKey(for: url)] = url.standardizedFileURL
        }
        return Array(byPath.values)
    }

    private func cleanup() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let query {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        }
        query = nil
    }
}
