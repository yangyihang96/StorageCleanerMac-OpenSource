import Dispatch
import Foundation

enum CompatibilitySpeedTestError: Error, Equatable, Sendable {
    case disallowedEndpoint
    case disallowedRedirect
    case httpStatus(Int)
    case earlyEOF
    case byteLimitExceeded
    case invalidResponse
    case invalidMeasurement
    case cancelled
    case transportFailed
}

struct CompatibilitySpeedTestParameters: Equatable, Sendable {
    static let standard = CompatibilitySpeedTestParameters(
        downloadBytes: 96 * 1_024 * 1_024,
        uploadBytes: 24 * 1_024 * 1_024,
        idleLatencySampleCount: 3,
        loadedLatencySampleCount: 5,
        auxiliaryResponseLimitBytes: 64 * 1_024
    )

    let downloadBytes: Int
    let uploadBytes: Int
    let idleLatencySampleCount: Int
    let loadedLatencySampleCount: Int
    let auxiliaryResponseLimitBytes: Int
}

actor TransferMeter {
    static let maximumApplicationPayloadBytes: UInt64 = 134_217_728

    private nonisolated let ledger: TransferLedger

    init(limitBytes: UInt64 = TransferMeter.maximumApplicationPayloadBytes) {
        ledger = TransferLedger(limitBytes: limitBytes)
    }

    var totalBytes: UInt64 { ledger.totalBytes }
    var limitBytes: UInt64 { ledger.limitBytes }

    nonisolated func claim(_ requestedBytes: Int) -> TransferClaim {
        ledger.claim(requestedBytes)
    }

    nonisolated func beginExclusiveRun(maximumPayloadBytes: UInt64) -> Bool {
        ledger.beginExclusiveRun(maximumPayloadBytes: maximumPayloadBytes)
    }

    nonisolated func endExclusiveRun() {
        ledger.endExclusiveRun()
    }
}

enum CompatibilityUploadAccounting {
    static func progressError(
        previousBytes: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64,
        expectedBytes: Int64
    ) -> CompatibilitySpeedTestError? {
        guard expectedBytes > 0,
              previousBytes >= 0,
              totalBytesSent >= previousBytes,
              totalBytesSent <= expectedBytes,
              totalBytesExpectedToSend < 0
                || totalBytesExpectedToSend == expectedBytes else {
            return .invalidMeasurement
        }
        return nil
    }

    static func terminalError(
        taskReportedBytes: Int64,
        expectedBytes: Int64
    ) -> CompatibilitySpeedTestError? {
        guard expectedBytes > 0, taskReportedBytes >= 0 else {
            return .invalidMeasurement
        }
        if taskReportedBytes < expectedBytes { return .earlyEOF }
        if taskReportedBytes > expectedBytes { return .invalidMeasurement }
        return nil
    }
}

enum CompatibilityPayloadIOAccounting {
    static func terminalError(
        observationRequired: Bool,
        observationRecorded: Bool
    ) -> CompatibilitySpeedTestError? {
        observationRequired && !observationRecorded ? .invalidMeasurement : nil
    }
}

struct CompatibilityLatencyStatistics: Equatable, Sendable {
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let madMilliseconds: Double

    static func evaluate(
        samplesMilliseconds: [Double]
    ) throws -> CompatibilityLatencyStatistics {
        guard !samplesMilliseconds.isEmpty,
              samplesMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }

        let sorted = samplesMilliseconds.sorted()
        let p50 = percentile(sorted, probability: 0.50)
        let p95 = percentile(sorted, probability: 0.95)
        let deviations = sorted.map { abs($0 - p50) }.sorted()
        let mad = percentile(deviations, probability: 0.50)
        guard p50.isFinite, p95.isFinite, mad.isFinite else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }
        return CompatibilityLatencyStatistics(
            p50Milliseconds: p50,
            p95Milliseconds: p95,
            madMilliseconds: mad
        )
    }

    private static func percentile(_ sorted: [Double], probability: Double) -> Double {
        guard sorted.count > 1 else { return sorted[0] }
        let position = Double(sorted.count - 1) * probability
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
    }
}

private enum CompatibilityLoadTransfer: Hashable {
    case download
    case upload
}

private final class CompatibilityLoadWindowGate: @unchecked Sendable {
    private let lock = NSLock()
    private var startedTransfers = Set<CompatibilityLoadTransfer>()
    private var failure: CompatibilitySpeedTestError?
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    func markStarted(_ transfer: CompatibilityLoadTransfer) {
        let readyWaiters: [CheckedContinuation<Void, any Error>]
        lock.lock()
        if failure == nil {
            startedTransfers.insert(transfer)
        }
        if failure == nil, startedTransfers.count == 2 {
            readyWaiters = waiters
            waiters.removeAll()
        } else {
            readyWaiters = []
        }
        lock.unlock()
        readyWaiters.forEach { $0.resume() }
    }

    func fail(with error: CompatibilitySpeedTestError) {
        let failedWaiters: [CheckedContinuation<Void, any Error>]
        lock.lock()
        if failure == nil {
            failure = error
            failedWaiters = waiters
            waiters.removeAll()
        } else {
            failedWaiters = []
        }
        lock.unlock()
        failedWaiters.forEach { $0.resume(throwing: error) }
    }

    func waitUntilTransfersStarted() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Void, CompatibilitySpeedTestError>?
                lock.lock()
                if let failure {
                    result = .failure(failure)
                } else if startedTransfers.count == 2 {
                    result = .success(())
                } else {
                    waiters.append(continuation)
                    result = nil
                }
                lock.unlock()
                switch result {
                case .success:
                    continuation.resume()
                case let .failure(error):
                    continuation.resume(throwing: error)
                case nil:
                    break
                }
            }
        } onCancel: {
            self.fail(with: .cancelled)
        }
    }
}

protocol NetworkCompatibilitySpeedTesting: Sendable {
    func test() async throws -> NetworkSpeedTestResult
}

struct NetworkCompatibilityCleanupContext: Sendable {
    fileprivate let lifetime: NetworkCompatibilitySessionLifetime

    func waitForVerifiedInvalidation() async {
        await lifetime.waitForVerifiedInvalidation()
    }
}

struct NetworkCompatibilitySpeedTestCleanupPendingError: Error, Sendable {
    let context: NetworkCompatibilityCleanupContext
}

fileprivate final class NetworkCompatibilitySessionLifetime: @unchecked Sendable {
    private let session: URLSession
    private let delegate: CompatibilitySessionDelegate

    init(session: URLSession, delegate: CompatibilitySessionDelegate) {
        self.session = session
        self.delegate = delegate
    }

    func waitForVerifiedInvalidation() async {
        // The store installs cleanup quarantine before entering this deliberate
        // unbounded wait, so no new heavy work can overlap the live session.
        await delegate.waitUntilSessionInvalidated()
        _ = session
    }
}

struct NetworkCompatibilitySpeedTestService: @unchecked Sendable {
    static let methodVersion = "compatibility-cloudflare-v1"
    static let resultCompleteness = 5.0 / 6.0
    static let allowedHost = "speed.cloudflare.com"
    static let allowedPaths: Set<String> = ["/__down", "/__up"]
    static let allowedInterfaceNames: Set<String> = ["wifi", "wired", "cellular", "other"]
    static let maximumApplicationPayloadBytes = TransferMeter.maximumApplicationPayloadBytes
    static let standardApplicationPayloadBytes = UInt64(
        CompatibilitySpeedTestParameters.standard.downloadBytes
            + CompatibilitySpeedTestParameters.standard.uploadBytes
    )
    static let maximumTotalLatencySampleCount = 64
    private static let maximumShutdownGraceSeconds: TimeInterval = 2
    static let applicationPayloadBudgetDisclosure =
        "128 MiB 是应用层正文预算；HTTP、TLS、TCP/IP 等协议开销与网络重传会产生额外流量。"
    static let loadedLatencyMethodDisclosure =
        "负载延迟探针在下载收到正文且上传实际发送数据后执行；重叠为尽力测量，不代表全程持续满载。"
    static let defaultDownloadEndpoint = URL(string: "https://speed.cloudflare.com/__down")!
    static let defaultUploadEndpoint = URL(string: "https://speed.cloudflare.com/__up")!

    private let meter: TransferMeter
    private let parameters: CompatibilitySpeedTestParameters
    private let downloadEndpoint: URL
    private let uploadEndpoint: URL
    private let interfaceName: String
    private let protocolClasses: [AnyClass]?
    private let now: @Sendable () -> Date
    private let monotonicSeconds: @Sendable () -> Double
    private let sentByteCount: @Sendable (URLSessionTask) -> Int64
    private let shutdownGraceSeconds: TimeInterval
    private let sessionInvalidator: @Sendable (URLSession) -> Void
    // Custom URLProtocol stubs do not emit didSendBodyData. Tests may inject
    // that observed event explicitly; production always leaves this nil.
    private let uploadProgressObservationForTesting: (@Sendable (URLSessionTask) -> Bool)?

    init(
        meter: TransferMeter = TransferMeter(),
        parameters: CompatibilitySpeedTestParameters = .standard,
        downloadEndpoint: URL = Self.defaultDownloadEndpoint,
        uploadEndpoint: URL = Self.defaultUploadEndpoint,
        interfaceName: String = "other",
        protocolClasses: [AnyClass]? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        monotonicSeconds: @escaping @Sendable () -> Double = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        },
        sentByteCount: @escaping @Sendable (URLSessionTask) -> Int64 = {
            $0.countOfBytesSent
        },
        shutdownGraceSeconds: TimeInterval = 1,
        sessionInvalidator: @escaping @Sendable (URLSession) -> Void = {
            $0.invalidateAndCancel()
        },
        uploadProgressObservationForTesting: (@Sendable (URLSessionTask) -> Bool)? = nil
    ) {
        self.meter = meter
        self.parameters = parameters
        self.downloadEndpoint = downloadEndpoint
        self.uploadEndpoint = uploadEndpoint
        self.interfaceName = interfaceName
        self.protocolClasses = protocolClasses
        self.now = now
        self.monotonicSeconds = monotonicSeconds
        self.sentByteCount = sentByteCount
        self.shutdownGraceSeconds = shutdownGraceSeconds.isFinite
            ? min(Self.maximumShutdownGraceSeconds, max(0, shutdownGraceSeconds))
            : 1
        self.sessionInvalidator = sessionInvalidator
        self.uploadProgressObservationForTesting = uploadProgressObservationForTesting
    }

    static func makeConfiguration(
        protocolClasses: [AnyClass]? = nil
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return configuration
    }

    func test() async throws -> NetworkSpeedTestResult {
        do {
            let worstCasePayloadBytes = try validateInputs()
            guard meter.beginExclusiveRun(maximumPayloadBytes: worstCasePayloadBytes) else {
                throw CompatibilitySpeedTestError.invalidMeasurement
            }
            defer { meter.endExclusiveRun() }
            return try await runExclusiveTest()
        } catch is CancellationError {
            throw CompatibilitySpeedTestError.cancelled
        } catch let error as NetworkCompatibilitySpeedTestCleanupPendingError {
            throw error
        } catch let error as CompatibilitySpeedTestError {
            throw error
        } catch {
            throw CompatibilitySpeedTestError.transportFailed
        }
    }

    private func runExclusiveTest() async throws -> NetworkSpeedTestResult {
        let startingPayloadBytes = await meter.totalBytes
        try Task.checkCancellation()

        let startedAt = monotonicSeconds()
        guard startedAt.isFinite, startedAt >= 0 else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }

        let delegate = CompatibilitySessionDelegate(
            meter: meter,
            monotonicSeconds: monotonicSeconds,
            sentByteCount: sentByteCount,
            uploadProgressObservationForTesting: uploadProgressObservationForTesting
        )
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.local.StorageCleanerMac.compatibility-speed-session"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        let session = URLSession(
            configuration: Self.makeConfiguration(protocolClasses: protocolClasses),
            delegate: delegate,
            delegateQueue: delegateQueue
        )
        let client = CompatibilityHTTPClient(
            session: session,
            delegate: delegate,
            monotonicSeconds: monotonicSeconds
        )

        let result: NetworkSpeedTestResult
        do {
            result = try await withTaskCancellationHandler {
                try await runTest(
                    client: client,
                    startedAt: startedAt,
                    startingPayloadBytes: startingPayloadBytes
                )
            } onCancel: {
                client.cancelAll(with: .cancelled)
            }
        } catch {
            let operationError = error
            try await shutDown(
                client: client,
                session: session,
                delegate: delegate
            )
            throw operationError
        }

        try await shutDown(
            client: client,
            session: session,
            delegate: delegate
        )
        return result
    }

    private func shutDown(
        client: CompatibilityHTTPClient,
        session: URLSession,
        delegate: CompatibilitySessionDelegate
    ) async throws {
        client.cancelAll(with: .cancelled)
        let lifetime = NetworkCompatibilitySessionLifetime(
            session: session,
            delegate: delegate
        )
        sessionInvalidator(session)
        guard await delegate.waitUntilSessionInvalidated(
            timeoutSeconds: shutdownGraceSeconds
        ) else {
            throw NetworkCompatibilitySpeedTestCleanupPendingError(
                context: NetworkCompatibilityCleanupContext(lifetime: lifetime)
            )
        }
    }

    private func runTest(
        client: CompatibilityHTTPClient,
        startedAt: Double,
        startingPayloadBytes: UInt64
    ) async throws -> NetworkSpeedTestResult {
        let idleSamples = try await measureLatencySamples(
            count: parameters.idleLatencySampleCount,
            phase: "idle",
            client: client
        )

        let loadWindowGate = CompatibilityLoadWindowGate()
        async let downloadMeasurement = measureDownload(
            client: client,
            loadWindowGate: loadWindowGate
        )
        async let uploadMeasurement = measureUpload(
            client: client,
            loadWindowGate: loadWindowGate
        )
        async let loadedSamples = measureLoadedLatencySamples(
            client: client,
            loadWindowGate: loadWindowGate
        )

        let (download, upload, loaded) = try await (
            downloadMeasurement,
            uploadMeasurement,
            loadedSamples
        )
        try Task.checkCancellation()

        let finishedAt = monotonicSeconds()
        let duration = try Self.validDuration(startedAt: startedAt, finishedAt: finishedAt)
        let idleStatistics = try CompatibilityLatencyStatistics.evaluate(
            samplesMilliseconds: idleSamples
        )
        let loadedStatistics = try CompatibilityLatencyStatistics.evaluate(
            samplesMilliseconds: loaded
        )
        let downloadMbps = try Self.throughputMbps(
            bytes: download.bytes,
            durationSeconds: download.durationSeconds
        )
        let uploadMbps = try Self.throughputMbps(
            bytes: upload.bytes,
            durationSeconds: upload.durationSeconds
        )
        let endingPayloadBytes = await meter.totalBytes
        let testedAt = now()

        guard endingPayloadBytes >= startingPayloadBytes,
              endingPayloadBytes - startingPayloadBytes
                <= TransferMeter.maximumApplicationPayloadBytes,
              testedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }
        let payloadBytes = endingPayloadBytes - startingPayloadBytes

        return NetworkSpeedTestResult(
            downloadMbps: downloadMbps,
            uploadMbps: uploadMbps,
            responsivenessRPM: nil,
            idleLatencyMilliseconds: idleStatistics.p50Milliseconds,
            loadedLatencyP50Milliseconds: loadedStatistics.p50Milliseconds,
            loadedLatencyP95Milliseconds: loadedStatistics.p95Milliseconds,
            jitterMilliseconds: loadedStatistics.madMilliseconds,
            interfaceName: interfaceName,
            source: .compatibilityEstimate,
            methodVersion: Self.methodVersion,
            durationSeconds: duration,
            transferredBytes: payloadBytes,
            completeness: Self.resultCompleteness,
            testedAt: testedAt
        )
    }

    private func measureDownload(
        client: CompatibilityHTTPClient,
        loadWindowGate: CompatibilityLoadWindowGate
    ) async throws -> CompatibilityTransferMeasurement {
        do {
            let request = try request(
                endpoint: downloadEndpoint,
                method: "GET",
                phase: "download",
                requestedBytes: parameters.downloadBytes
            )
            let response = try await client.perform(
                request,
                uploadBody: nil,
                minimumResponseBytes: parameters.downloadBytes,
                maximumResponseBytes: parameters.downloadBytes,
                onPayloadIOStarted: { loadWindowGate.markStarted(.download) }
            )
            return CompatibilityTransferMeasurement(
                bytes: response.responseBytes,
                durationSeconds: response.durationSeconds
            )
        } catch {
            loadWindowGate.fail(with: Self.compatibilityError(from: error))
            throw error
        }
    }

    private func measureUpload(
        client: CompatibilityHTTPClient,
        loadWindowGate: CompatibilityLoadWindowGate
    ) async throws -> CompatibilityTransferMeasurement {
        do {
            try Task.checkCancellation()
            let claim = meter.claim(parameters.uploadBytes)
            guard claim.acceptedBytes == parameters.uploadBytes else {
                client.cancelAll(with: .byteLimitExceeded)
                throw CompatibilitySpeedTestError.byteLimitExceeded
            }

            var request = try request(
                endpoint: uploadEndpoint,
                method: "POST",
                phase: "upload",
                requestedBytes: nil
            )
            request.setValue(
                String(parameters.uploadBytes),
                forHTTPHeaderField: "Content-Length"
            )
            let body = Data(repeating: 0, count: parameters.uploadBytes)
            let response = try await client.perform(
                request,
                uploadBody: body,
                minimumResponseBytes: 0,
                maximumResponseBytes: parameters.auxiliaryResponseLimitBytes,
                onPayloadIOStarted: { loadWindowGate.markStarted(.upload) }
            )
            return CompatibilityTransferMeasurement(
                bytes: UInt64(parameters.uploadBytes),
                durationSeconds: response.durationSeconds
            )
        } catch {
            loadWindowGate.fail(with: Self.compatibilityError(from: error))
            throw error
        }
    }

    private func measureLoadedLatencySamples(
        client: CompatibilityHTTPClient,
        loadWindowGate: CompatibilityLoadWindowGate
    ) async throws -> [Double] {
        try await loadWindowGate.waitUntilTransfersStarted()
        try Task.checkCancellation()
        return try await measureLatencySamples(
            count: parameters.loadedLatencySampleCount,
            phase: "loaded",
            client: client
        )
    }

    private static func compatibilityError(from error: any Error) -> CompatibilitySpeedTestError {
        if error is CancellationError { return .cancelled }
        return error as? CompatibilitySpeedTestError ?? .transportFailed
    }

    private func measureLatencySamples(
        count: Int,
        phase: String,
        client: CompatibilityHTTPClient
    ) async throws -> [Double] {
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for sampleIndex in 0..<count {
            try Task.checkCancellation()
            let request = try request(
                endpoint: downloadEndpoint,
                method: "GET",
                phase: phase,
                requestedBytes: 0,
                sampleIndex: sampleIndex
            )
            let response = try await client.perform(
                request,
                uploadBody: nil,
                minimumResponseBytes: 0,
                maximumResponseBytes: parameters.auxiliaryResponseLimitBytes
            )
            let milliseconds = response.durationSeconds * 1_000
            guard milliseconds.isFinite, milliseconds >= 0 else {
                throw CompatibilitySpeedTestError.invalidMeasurement
            }
            samples.append(milliseconds)
        }
        return samples
    }

    private func request(
        endpoint: URL,
        method: String,
        phase: String,
        requestedBytes: Int?,
        sampleIndex: Int? = nil
    ) throws -> URLRequest {
        guard Self.isAllowedEndpoint(endpoint),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw CompatibilitySpeedTestError.disallowedEndpoint
        }
        var queryItems = [URLQueryItem(name: "phase", value: phase)]
        if let requestedBytes {
            queryItems.append(URLQueryItem(name: "bytes", value: String(requestedBytes)))
        }
        if let sampleIndex {
            queryItems.append(URLQueryItem(name: "sample", value: String(sampleIndex)))
        }
        components.queryItems = queryItems
        guard let url = components.url, Self.isAllowedEndpoint(url) else {
            throw CompatibilitySpeedTestError.disallowedEndpoint
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if method == "POST" {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func validateInputs() throws -> UInt64 {
        guard Self.isAllowedEndpoint(downloadEndpoint),
              Self.isAllowedEndpoint(uploadEndpoint),
              downloadEndpoint.path == "/__down",
              uploadEndpoint.path == "/__up" else {
            throw CompatibilitySpeedTestError.disallowedEndpoint
        }

        guard parameters.downloadBytes > 0,
              parameters.uploadBytes > 0,
              parameters.idleLatencySampleCount > 0,
              parameters.loadedLatencySampleCount > 0,
              parameters.idleLatencySampleCount <= Self.maximumTotalLatencySampleCount,
              parameters.loadedLatencySampleCount <= Self.maximumTotalLatencySampleCount,
              parameters.idleLatencySampleCount
                <= Self.maximumTotalLatencySampleCount - parameters.loadedLatencySampleCount,
              parameters.auxiliaryResponseLimitBytes >= 0,
              Self.allowedInterfaceNames.contains(interfaceName) else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }

        let idleSampleCount = UInt64(parameters.idleLatencySampleCount)
        let loadedSampleCount = UInt64(parameters.loadedLatencySampleCount)
        let auxiliaryResponseLimit = UInt64(parameters.auxiliaryResponseLimitBytes)
        let latencySampleCount = idleSampleCount.addingReportingOverflow(loadedSampleCount)
        guard !latencySampleCount.overflow else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }
        // The upload request can also return a response, so it consumes one
        // additional auxiliary-response allowance beyond the latency probes.
        let auxiliaryRequestCount = latencySampleCount.partialValue.addingReportingOverflow(1)
        guard !auxiliaryRequestCount.overflow else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }
        let auxiliaryBudget = auxiliaryRequestCount.partialValue
            .multipliedReportingOverflow(by: auxiliaryResponseLimit)
        guard !auxiliaryBudget.overflow else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }
        let downloadAndUpload = UInt64(parameters.downloadBytes)
            .addingReportingOverflow(UInt64(parameters.uploadBytes))
        guard !downloadAndUpload.overflow else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }
        let worstCaseTransfer = downloadAndUpload.partialValue
            .addingReportingOverflow(auxiliaryBudget.partialValue)
        guard !worstCaseTransfer.overflow else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }

        guard worstCaseTransfer.partialValue
                <= TransferMeter.maximumApplicationPayloadBytes else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }
        return worstCaseTransfer.partialValue
    }

    static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == allowedHost
            && allowedPaths.contains(components.path)
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.fragment == nil
    }

    static func isAllowedRedirect(
        from original: URL,
        to destination: URL,
        originalMethod: String,
        redirectedMethod: String
    ) -> Bool {
        let normalizedOriginalMethod = originalMethod.uppercased()
        return ["GET", "HEAD"].contains(normalizedOriginalMethod)
            && normalizedOriginalMethod == redirectedMethod.uppercased()
            && isAllowedRedirectLocation(from: original, to: destination)
    }

    static func isAllowedRedirectLocation(from original: URL, to destination: URL) -> Bool {
        guard isAllowedEndpoint(original), isAllowedEndpoint(destination),
              let originalComponents = URLComponents(
                url: original,
                resolvingAgainstBaseURL: false
              ),
              let destinationComponents = URLComponents(
                url: destination,
                resolvingAgainstBaseURL: false
              ) else {
            return false
        }
        return originalComponents.scheme?.lowercased()
                == destinationComponents.scheme?.lowercased()
            && originalComponents.host?.lowercased()
                == destinationComponents.host?.lowercased()
            && originalComponents.path == destinationComponents.path
    }

    private static func validDuration(
        startedAt: Double,
        finishedAt: Double
    ) throws -> Double {
        let duration = finishedAt - startedAt
        guard startedAt.isFinite, finishedAt.isFinite,
              duration.isFinite, duration > 0 else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }
        return duration
    }

    private static func throughputMbps(
        bytes: UInt64,
        durationSeconds: Double
    ) throws -> Double {
        guard bytes > 0, durationSeconds.isFinite, durationSeconds > 0 else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }
        let value = Double(bytes) * 8 / durationSeconds / 1_000_000
        guard value.isFinite, value >= 0 else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }
        return value
    }
}

extension NetworkCompatibilitySpeedTestService: NetworkCompatibilitySpeedTesting {}

struct TransferClaim: Sendable {
    let acceptedBytes: Int
}

private final class TransferLedger: @unchecked Sendable {
    let limitBytes: UInt64

    private let lock = NSLock()
    private var recordedTotalBytes: UInt64 = 0
    private var recordedRunBytes: UInt64 = 0
    private var hasActiveRun = false

    init(limitBytes: UInt64) {
        self.limitBytes = min(limitBytes, TransferMeter.maximumApplicationPayloadBytes)
    }

    var totalBytes: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return recordedTotalBytes
    }

    func claim(_ requestedBytes: Int) -> TransferClaim {
        guard requestedBytes > 0 else { return TransferClaim(acceptedBytes: 0) }
        lock.lock()
        defer { lock.unlock() }
        guard hasActiveRun else { return TransferClaim(acceptedBytes: 0) }
        let remaining = limitBytes >= recordedRunBytes ? limitBytes - recordedRunBytes : 0
        let accepted = min(UInt64(requestedBytes), remaining)
        let nextRunBytes = recordedRunBytes.addingReportingOverflow(accepted)
        let nextTotalBytes = recordedTotalBytes.addingReportingOverflow(accepted)
        guard !nextRunBytes.overflow, !nextTotalBytes.overflow else {
            return TransferClaim(acceptedBytes: 0)
        }
        recordedRunBytes = nextRunBytes.partialValue
        recordedTotalBytes = nextTotalBytes.partialValue
        return TransferClaim(acceptedBytes: Int(accepted))
    }

    func beginExclusiveRun(maximumPayloadBytes: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasActiveRun,
              maximumPayloadBytes > 0,
              maximumPayloadBytes <= limitBytes else {
            return false
        }
        hasActiveRun = true
        recordedRunBytes = 0
        return true
    }

    func endExclusiveRun() {
        lock.lock()
        hasActiveRun = false
        recordedRunBytes = 0
        lock.unlock()
    }
}

private struct CompatibilityTransferMeasurement: Sendable {
    let bytes: UInt64
    let durationSeconds: Double
}

private struct CompatibilityHTTPMeasurement: Sendable {
    let responseBytes: UInt64
    let durationSeconds: Double
}

final class CompatibilityOneShotUploadBody: @unchecked Sendable {
    let byteCount: Int64

    private let lock = NSLock()
    private let data: Data
    private var didIssueStream = false

    init(data: Data) {
        self.data = data
        byteCount = Int64(data.count)
    }

    func takeStream(requestedOffset: Int64?) -> InputStream? {
        lock.lock()
        defer { lock.unlock() }
        guard requestedOffset == nil || requestedOffset == 0,
              !didIssueStream else {
            return nil
        }
        didIssueStream = true
        return InputStream(data: data)
    }
}

private final class CompatibilityHTTPClient: @unchecked Sendable {
    private let session: URLSession
    private let delegate: CompatibilitySessionDelegate
    private let monotonicSeconds: @Sendable () -> Double

    init(
        session: URLSession,
        delegate: CompatibilitySessionDelegate,
        monotonicSeconds: @escaping @Sendable () -> Double
    ) {
        self.session = session
        self.delegate = delegate
        self.monotonicSeconds = monotonicSeconds
    }

    func perform(
        _ request: URLRequest,
        uploadBody: Data?,
        minimumResponseBytes: Int,
        maximumResponseBytes: Int,
        onPayloadIOStarted: (@Sendable () -> Void)? = nil
    ) async throws -> CompatibilityHTTPMeasurement {
        try Task.checkCancellation()
        guard let originalURL = request.url,
              let originalMethod = request.httpMethod?.uppercased(),
              !originalMethod.isEmpty,
              NetworkCompatibilitySpeedTestService.isAllowedEndpoint(originalURL) else {
            throw CompatibilitySpeedTestError.disallowedEndpoint
        }
        guard minimumResponseBytes >= 0,
              maximumResponseBytes >= minimumResponseBytes else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }
        if let uploadBody {
            guard request.value(forHTTPHeaderField: "Content-Length")
                    == String(uploadBody.count) else {
                throw CompatibilitySpeedTestError.invalidMeasurement
            }
        }
        let startedAt = monotonicSeconds()
        guard startedAt.isFinite, startedAt >= 0 else {
            throw CompatibilitySpeedTestError.invalidMeasurement
        }

        let uploadSource = uploadBody.map { CompatibilityOneShotUploadBody(data: $0) }
        let task: URLSessionTask
        if uploadSource != nil {
            task = session.uploadTask(withStreamedRequest: request)
        } else {
            task = session.dataTask(with: request)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let context = CompatibilityRequestContext(
                    task: task,
                    originalURL: originalURL,
                    originalMethod: originalMethod,
                    uploadSource: uploadSource,
                    minimumResponseBytes: UInt64(minimumResponseBytes),
                    maximumResponseBytes: UInt64(maximumResponseBytes),
                    startedAt: startedAt,
                    onPayloadIOStarted: onPayloadIOStarted,
                    continuation: continuation
                )
                let shouldStart = delegate.register(context)
                if shouldStart {
                    task.resume()
                }
            }
        } onCancel: {
            self.delegate.cancel(task: task, with: .cancelled)
        }
    }

    func cancelAll(with error: CompatibilitySpeedTestError) {
        delegate.cancelAll(with: error)
    }
}

private final class CompatibilitySessionDelegate:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let meter: TransferMeter
    private let monotonicSeconds: @Sendable () -> Double
    private let sentByteCount: @Sendable (URLSessionTask) -> Int64
    private let uploadProgressObservationForTesting: (@Sendable (URLSessionTask) -> Bool)?
    private var contexts: [Int: CompatibilityRequestContext] = [:]
    private var pendingFailures: [Int: CompatibilitySpeedTestError] = [:]
    private var globalFailure: CompatibilitySpeedTestError?
    private var didInvalidateSession = false
    private var invalidationWaiters: [CheckedContinuation<Void, Never>] = []
    private var timedInvalidationWaiters: [
        UUID: CheckedContinuation<Bool, Never>
    ] = [:]

    init(
        meter: TransferMeter,
        monotonicSeconds: @escaping @Sendable () -> Double,
        sentByteCount: @escaping @Sendable (URLSessionTask) -> Int64,
        uploadProgressObservationForTesting: (@Sendable (URLSessionTask) -> Bool)?
    ) {
        self.meter = meter
        self.monotonicSeconds = monotonicSeconds
        self.sentByteCount = sentByteCount
        self.uploadProgressObservationForTesting = uploadProgressObservationForTesting
    }

    func register(_ context: CompatibilityRequestContext) -> Bool {
        let failure: CompatibilitySpeedTestError?
        lock.lock()
        failure = globalFailure ?? pendingFailures.removeValue(forKey: context.task.taskIdentifier)
        if failure == nil {
            contexts[context.task.taskIdentifier] = context
        }
        lock.unlock()

        if let failure {
            context.task.cancel()
            context.complete(.failure(failure))
            return false
        }
        return true
    }

    func cancel(task: URLSessionTask, with error: CompatibilitySpeedTestError) {
        let context: CompatibilityRequestContext?
        lock.lock()
        context = contexts.removeValue(forKey: task.taskIdentifier)
        if context == nil, globalFailure == nil {
            pendingFailures[task.taskIdentifier] = error
        }
        lock.unlock()

        task.cancel()
        context?.complete(.failure(error))
    }

    func cancelAll(with error: CompatibilitySpeedTestError) {
        let activeContexts: [CompatibilityRequestContext]
        lock.lock()
        if globalFailure == nil {
            globalFailure = error
        }
        activeContexts = Array(contexts.values)
        contexts.removeAll()
        lock.unlock()

        for context in activeContexts {
            context.task.cancel()
            context.complete(.failure(error))
        }
    }

    func waitUntilSessionInvalidated() async {
        await withCheckedContinuation { continuation in
            let isInvalidated: Bool
            lock.lock()
            isInvalidated = didInvalidateSession
            if !isInvalidated {
                invalidationWaiters.append(continuation)
            }
            lock.unlock()
            if isInvalidated {
                continuation.resume()
            }
        }
    }

    func waitUntilSessionInvalidated(timeoutSeconds: TimeInterval) async -> Bool {
        // Cancellation must not release the session early. The deadline is the
        // only fast-exit path; a later callback is handed to cleanup quarantine.
        await withCheckedContinuation { continuation in
            let waiterID = UUID()
            let isInvalidated: Bool
            lock.lock()
            isInvalidated = didInvalidateSession
            if !isInvalidated {
                timedInvalidationWaiters[waiterID] = continuation
            }
            lock.unlock()

            if isInvalidated {
                continuation.resume(returning: true)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeoutSeconds
            ) { [self] in
                expireInvalidationWaiter(waiterID)
            }
        }
    }

    func urlSession(
        _: URLSession,
        didBecomeInvalidWithError error: (any Error)?
    ) {
        if error != nil {
            cancelAll(with: .transportFailed)
        }

        let waiters: [CheckedContinuation<Void, Never>]
        let timedWaiters: [CheckedContinuation<Bool, Never>]
        lock.lock()
        didInvalidateSession = true
        waiters = invalidationWaiters
        invalidationWaiters.removeAll()
        timedWaiters = Array(timedInvalidationWaiters.values)
        timedInvalidationWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
        timedWaiters.forEach { $0.resume(returning: true) }
    }

    private func expireInvalidationWaiter(_ waiterID: UUID) {
        let waiter: CheckedContinuation<Bool, Never>?
        lock.lock()
        waiter = timedInvalidationWaiters.removeValue(forKey: waiterID)
        lock.unlock()
        waiter?.resume(returning: false)
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let context = context(for: task.taskIdentifier),
              let destination = request.url,
              NetworkCompatibilitySpeedTestService.isAllowedRedirect(
                from: context.originalURL,
                to: destination,
                originalMethod: context.originalMethod,
                redirectedMethod: request.httpMethod ?? ""
              ) else {
            completionHandler(nil)
            cancelAll(with: .disallowedRedirect)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        guard let context = context(for: task.taskIdentifier),
              context.expectedUploadBytes != nil else {
            completionHandler(nil)
            return
        }
        guard let stream = context.takeUploadStream(requestedOffset: nil) else {
            completionHandler(nil)
            cancelAll(with: .invalidMeasurement)
            return
        }
        completionHandler(stream)
    }

    @available(macOS 14.0, *)
    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        needNewBodyStreamFrom offset: Int64,
        completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        guard let context = context(for: task.taskIdentifier),
              context.expectedUploadBytes != nil else {
            completionHandler(nil)
            return
        }
        guard let stream = context.takeUploadStream(requestedOffset: offset) else {
            completionHandler(nil)
            cancelAll(with: .invalidMeasurement)
            return
        }
        completionHandler(stream)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let context = context(for: dataTask.taskIdentifier),
              let httpResponse = response as? HTTPURLResponse,
              let responseURL = httpResponse.url,
              NetworkCompatibilitySpeedTestService.isAllowedRedirectLocation(
                from: context.originalURL,
                to: responseURL
              ) else {
            completionHandler(.cancel)
            cancelAll(with: .invalidResponse)
            return
        }

        if (300..<400).contains(httpResponse.statusCode),
           let location = httpResponse.value(forHTTPHeaderField: "Location"),
           let destination = URL(string: location, relativeTo: responseURL)?.absoluteURL,
           !NetworkCompatibilitySpeedTestService.isAllowedRedirect(
                from: context.originalURL,
                to: destination,
                originalMethod: context.originalMethod,
                redirectedMethod: context.originalMethod
           ) {
            completionHandler(.cancel)
            cancelAll(with: .disallowedRedirect)
            return
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            completionHandler(.cancel)
            cancelAll(with: .httpStatus(httpResponse.statusCode))
            return
        }

        let expectedLength = response.expectedContentLength
        guard expectedLength >= 0 else {
            completionHandler(.cancel)
            cancelAll(with: .invalidResponse)
            return
        }
        let length = UInt64(expectedLength)
        if length < context.minimumResponseBytes {
            completionHandler(.cancel)
            cancelAll(with: .earlyEOF)
            return
        }
        if length > context.maximumResponseBytes {
            completionHandler(.cancel)
            cancelAll(with: .byteLimitExceeded)
            return
        }
        context.markResponseAccepted(declaredResponseBytes: length)
        completionHandler(.allow)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let context = context(for: dataTask.taskIdentifier) else { return }
        guard context.recordResponseBytes(data.count) == .accepted else {
            cancelAll(with: .byteLimitExceeded)
            return
        }
        let claim = meter.claim(data.count)
        guard claim.acceptedBytes == data.count else {
            cancelAll(with: .byteLimitExceeded)
            return
        }
        if !data.isEmpty {
            context.markPayloadIOStarted()
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didSendBodyData _: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let context = context(for: task.taskIdentifier) else { return }
        switch context.recordUploadProgress(
            totalBytesSent: totalBytesSent,
            totalBytesExpectedToSend: totalBytesExpectedToSend
        ) {
        case .accepted:
            if totalBytesSent > 0 {
                context.markPayloadIOStarted()
            }
            return
        case .terminal:
            return
        case .invalid:
            cancelAll(with: .invalidMeasurement)
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let context = removeContext(for: task.taskIdentifier) else { return }
        if let error {
            let nsError = error as NSError
            let mapped: CompatibilitySpeedTestError = nsError.domain == NSURLErrorDomain
                && nsError.code == NSURLErrorCancelled
                ? .cancelled
                : .transportFailed
            fail(context, with: mapped)
            return
        }
        guard context.didAcceptResponse else {
            fail(context, with: .invalidResponse)
            return
        }
        guard context.responseBytes >= context.minimumResponseBytes else {
            fail(context, with: .earlyEOF)
            return
        }
        guard let declaredResponseBytes = context.declaredResponseBytes else {
            fail(context, with: .invalidResponse)
            return
        }
        guard context.responseBytes == declaredResponseBytes else {
            fail(
                context,
                with: context.responseBytes < declaredResponseBytes
                    ? .earlyEOF
                    : .invalidResponse
            )
            return
        }
        if let uploadError = context.uploadValidationError(
            taskReportedBytes: sentByteCount(task)
        ) {
            fail(context, with: uploadError)
            return
        }
        if uploadProgressObservationForTesting?(task) == true {
            context.markPayloadIOStarted()
        }
        if let payloadIOError = context.payloadIOValidationError() {
            fail(context, with: payloadIOError)
            return
        }
        let finishedAt = monotonicSeconds()
        let duration = finishedAt - context.startedAt
        guard finishedAt.isFinite, duration.isFinite, duration > 0 else {
            fail(context, with: .invalidMeasurement)
            return
        }
        context.complete(.success(CompatibilityHTTPMeasurement(
            responseBytes: context.responseBytes,
            durationSeconds: duration
        )))
    }

    private func context(for taskIdentifier: Int) -> CompatibilityRequestContext? {
        lock.lock()
        defer { lock.unlock() }
        return contexts[taskIdentifier]
    }

    private func removeContext(for taskIdentifier: Int) -> CompatibilityRequestContext? {
        lock.lock()
        defer { lock.unlock() }
        return contexts.removeValue(forKey: taskIdentifier)
    }

    private func fail(
        _ context: CompatibilityRequestContext,
        with error: CompatibilitySpeedTestError
    ) {
        context.complete(.failure(error))
        cancelAll(with: error)
    }
}

private final class CompatibilityRequestContext: @unchecked Sendable {
    enum RecordOutcome {
        case accepted
        case exceededResponseLimit
        case terminal
    }

    enum UploadProgressOutcome {
        case accepted
        case invalid
        case terminal
    }

    let task: URLSessionTask
    let originalURL: URL
    let originalMethod: String
    let minimumResponseBytes: UInt64
    let maximumResponseBytes: UInt64
    let startedAt: Double

    private let lock = NSLock()
    private let uploadSource: CompatibilityOneShotUploadBody?
    private let payloadIOObservationRequired: Bool
    private var onPayloadIOStarted: (@Sendable () -> Void)?
    private var continuation: CheckedContinuation<CompatibilityHTTPMeasurement, any Error>?
    private var acceptedResponse = false
    private var acceptedDeclaredResponseBytes: UInt64?
    private var recordedResponseBytes: UInt64 = 0
    private var reportedUploadBytes: Int64 = 0
    private var didObservePayloadIO = false
    private var terminal = false

    init(
        task: URLSessionTask,
        originalURL: URL,
        originalMethod: String,
        uploadSource: CompatibilityOneShotUploadBody?,
        minimumResponseBytes: UInt64,
        maximumResponseBytes: UInt64,
        startedAt: Double,
        onPayloadIOStarted: (@Sendable () -> Void)?,
        continuation: CheckedContinuation<CompatibilityHTTPMeasurement, any Error>
    ) {
        self.task = task
        self.originalURL = originalURL
        self.originalMethod = originalMethod
        self.uploadSource = uploadSource
        self.minimumResponseBytes = minimumResponseBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.startedAt = startedAt
        payloadIOObservationRequired = onPayloadIOStarted != nil
        self.onPayloadIOStarted = onPayloadIOStarted
        self.continuation = continuation
    }

    var didAcceptResponse: Bool { withLock { acceptedResponse && !terminal } }
    var declaredResponseBytes: UInt64? { withLock { acceptedDeclaredResponseBytes } }
    var responseBytes: UInt64 { withLock { recordedResponseBytes } }
    var expectedUploadBytes: Int64? { uploadSource?.byteCount }

    func takeUploadStream(requestedOffset: Int64?) -> InputStream? {
        uploadSource?.takeStream(requestedOffset: requestedOffset)
    }

    func markResponseAccepted(declaredResponseBytes: UInt64) {
        withLock {
            guard !terminal else { return }
            acceptedResponse = true
            acceptedDeclaredResponseBytes = declaredResponseBytes
        }
    }

    func markPayloadIOStarted() {
        let callback: (@Sendable () -> Void)? = withLock {
            guard !terminal else { return nil }
            didObservePayloadIO = true
            let callback = onPayloadIOStarted
            onPayloadIOStarted = nil
            return callback
        }
        callback?()
    }

    func payloadIOValidationError() -> CompatibilitySpeedTestError? {
        withLock {
            CompatibilityPayloadIOAccounting.terminalError(
                observationRequired: payloadIOObservationRequired,
                observationRecorded: didObservePayloadIO
            )
        }
    }

    func recordResponseBytes(_ count: Int) -> RecordOutcome {
        withLock {
            guard !terminal else { return .terminal }
            let addition = UInt64(max(0, count))
            let declaredLimit = acceptedDeclaredResponseBytes ?? maximumResponseBytes
            let effectiveLimit = min(maximumResponseBytes, declaredLimit)
            guard recordedResponseBytes <= effectiveLimit,
                  addition <= effectiveLimit - recordedResponseBytes else {
                return .exceededResponseLimit
            }
            recordedResponseBytes += addition
            return .accepted
        }
    }

    func recordUploadProgress(
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) -> UploadProgressOutcome {
        withLock {
            guard !terminal else { return .terminal }
            guard let expectedUploadBytes else {
                return totalBytesSent == 0 ? .accepted : .invalid
            }
            guard CompatibilityUploadAccounting.progressError(
                previousBytes: reportedUploadBytes,
                totalBytesSent: totalBytesSent,
                totalBytesExpectedToSend: totalBytesExpectedToSend,
                expectedBytes: expectedUploadBytes
            ) == nil else {
                return .invalid
            }
            reportedUploadBytes = totalBytesSent
            return .accepted
        }
    }

    func uploadValidationError(
        taskReportedBytes: Int64
    ) -> CompatibilitySpeedTestError? {
        withLock {
            guard let expectedUploadBytes else { return nil }
            return CompatibilityUploadAccounting.terminalError(
                taskReportedBytes: taskReportedBytes,
                expectedBytes: expectedUploadBytes
            )
        }
    }

    func complete(_ result: Result<CompatibilityHTTPMeasurement, CompatibilitySpeedTestError>) {
        lock.lock()
        guard !terminal else {
            lock.unlock()
            return
        }
        terminal = true
        onPayloadIOStarted = nil
        let pendingContinuation = continuation
        continuation = nil
        lock.unlock()

        switch result {
        case let .success(measurement):
            pendingContinuation?.resume(returning: measurement)
        case let .failure(error):
            pendingContinuation?.resume(throwing: error)
        }
    }

    @discardableResult
    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
