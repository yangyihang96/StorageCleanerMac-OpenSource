import Darwin
import Dispatch
import Foundation
import os

enum NetworkTestSource: String, Codable, Sendable {
    case nativeSystem
    case compatibilityEstimate
}

struct NetworkSpeedTestResult: Equatable, Codable, Sendable {
    let downloadMbps: Double
    let uploadMbps: Double
    let responsivenessRPM: Double?
    let idleLatencyMilliseconds: Double
    let loadedLatencyP50Milliseconds: Double?
    let loadedLatencyP95Milliseconds: Double?
    let jitterMilliseconds: Double?
    let interfaceName: String
    let source: NetworkTestSource
    let methodVersion: String
    let durationSeconds: Double
    let transferredBytes: UInt64?
    let completeness: Double
    let testedAt: Date
}

enum NetworkSpeedTestError: Error, Equatable, Sendable {
    case invalidOutput
    case outputTooLarge
    case offline
    case timedOut
    case cancelled
    case serviceUnavailable
    case failed
    case terminationFailed
}

struct NetworkQualityCleanupContext: Sendable {
    fileprivate let operationID: UUID
    fileprivate let reaper: NetworkQualityProcessReaper

    func waitForVerifiedExit() async {
        await reaper.waitUntilReleased(operationID: operationID)
    }
}

struct NetworkSpeedTestCleanupPendingError: Error, Sendable {
    let context: NetworkQualityCleanupContext
}

struct NetworkQualityCommand: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let watchdog: Duration
    let outputByteLimit: Int
}

struct NetworkQualityCommandOutput: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

protocol NetworkQualityRunning: Sendable {
    func run(_ command: NetworkQualityCommand) async throws -> NetworkQualityCommandOutput
}

struct NetworkSpeedTestService: Sendable {
    static let executablePath = "/usr/bin/networkQuality"
    static let arguments = ["-c", "-M", "20"]
    static let defaultWatchdog: Duration = .seconds(25)
    static let outputByteLimit = 1_048_576
    static let nativeMethodVersion = "native-network-quality-v1"

    // Coverage is defined against the six inputs used by the documented
    // network-experience model: download, upload, idle latency, loaded P95,
    // jitter, and RPM. networkQuality currently supplies four of those six.
    static let nativeCompleteness = 4.0 / 6.0

    private let runner: any NetworkQualityRunning
    private let watchdog: Duration
    private let serviceUnavailableRetryDelay: Duration
    private let now: @Sendable () -> Date
    private let monotonicNanoseconds: @Sendable () -> UInt64

    init(
        runner: any NetworkQualityRunning = NetworkQualityProcessRunner(),
        watchdog: Duration = Self.defaultWatchdog,
        serviceUnavailableRetryDelay: Duration = .milliseconds(1_500),
        now: @escaping @Sendable () -> Date = { Date() },
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.runner = runner
        self.watchdog = watchdog
        self.serviceUnavailableRetryDelay = serviceUnavailableRetryDelay
        self.now = now
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    func test() async throws -> NetworkSpeedTestResult {
        let startedAtNanoseconds = monotonicNanoseconds()
        let command = NetworkQualityCommand(
            executablePath: Self.executablePath,
            arguments: Self.arguments,
            watchdog: watchdog,
            outputByteLimit: Self.outputByteLimit
        )

        do {
            var acceptedOutput: NetworkQualityCommandOutput?
            for attempt in 0..<2 {
                let output = try await runner.run(command)
                try Task.checkCancellation()
                try Self.validateOutputSize(output, limit: command.outputByteLimit)
                if Self.indicatesServiceUnavailable(output) {
                    guard attempt == 0 else {
                        throw NetworkSpeedTestError.serviceUnavailable
                    }
                    try await Task.sleep(for: serviceUnavailableRetryDelay)
                    continue
                }
                acceptedOutput = output
                break
            }
            guard let output = acceptedOutput else {
                throw NetworkSpeedTestError.serviceUnavailable
            }
            if Self.indicatesOffline(output) {
                throw NetworkSpeedTestError.offline
            }
            guard output.terminationStatus == 0 else {
                throw NetworkSpeedTestError.failed
            }

            let finishedAtNanoseconds = monotonicNanoseconds()
            let elapsedNanoseconds = finishedAtNanoseconds >= startedAtNanoseconds
                ? finishedAtNanoseconds - startedAtNanoseconds
                : 0
            let result = try Self.parse(
                output.standardOutput,
                testedAt: now(),
                durationSeconds: Double(elapsedNanoseconds) / 1_000_000_000
            )
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw NetworkSpeedTestError.cancelled
        } catch let error as NetworkSpeedTestCleanupPendingError {
            throw error
        } catch let error as NetworkSpeedTestError {
            throw error
        } catch {
            throw NetworkSpeedTestError.failed
        }
    }

    static func parse(
        _ data: Data,
        testedAt: Date = Date(),
        durationSeconds: Double = 0
    ) throws -> NetworkSpeedTestResult {
        guard !data.isEmpty, data.count <= outputByteLimit else {
            throw data.isEmpty ? NetworkSpeedTestError.invalidOutput : .outputTooLarge
        }
        guard durationSeconds.isFinite, durationSeconds >= 0 else {
            throw NetworkSpeedTestError.invalidOutput
        }

        let object = try decodedObject(from: data)
        let downloadMbps = try quantity(
            in: object,
            fields: [
                QuantityField("dl_throughput", defaultUnit: .bitsPerSecond),
                QuantityField("downlink_throughput_bps", defaultUnit: .bitsPerSecond),
                QuantityField("downlink_capacity_mbps", defaultUnit: .megabitsPerSecond)
            ],
            kind: .throughput,
            maximum: 1_000_000
        )
        let uploadMbps = try quantity(
            in: object,
            fields: [
                QuantityField("ul_throughput", defaultUnit: .bitsPerSecond),
                QuantityField("uplink_throughput_bps", defaultUnit: .bitsPerSecond),
                QuantityField("uplink_capacity_mbps", defaultUnit: .megabitsPerSecond)
            ],
            kind: .throughput,
            maximum: 1_000_000
        )
        let responsiveness = try quantity(
            in: object,
            fields: [
                QuantityField("responsiveness", defaultUnit: .rpm),
                QuantityField("responsiveness_rpm", defaultUnit: .rpm)
            ],
            kind: .responsiveness,
            maximum: 10_000_000
        )
        let idleLatencyMilliseconds = try quantity(
            in: object,
            fields: [
                QuantityField("base_rtt", defaultUnit: .milliseconds),
                QuantityField("idle_latency_ms", defaultUnit: .milliseconds)
            ],
            kind: .latency,
            maximum: 86_400_000
        )
        let interfaceName = try interfaceName(in: object)

        return NetworkSpeedTestResult(
            downloadMbps: downloadMbps,
            uploadMbps: uploadMbps,
            responsivenessRPM: responsiveness,
            idleLatencyMilliseconds: idleLatencyMilliseconds,
            loadedLatencyP50Milliseconds: nil,
            loadedLatencyP95Milliseconds: nil,
            jitterMilliseconds: nil,
            interfaceName: interfaceName,
            source: .nativeSystem,
            methodVersion: nativeMethodVersion,
            durationSeconds: durationSeconds,
            transferredBytes: transferredBytes(in: object),
            completeness: nativeCompleteness,
            testedAt: testedAt
        )
    }

    private enum QuantityKind {
        case throughput
        case responsiveness
        case latency
    }

    private enum QuantityUnit {
        case bitsPerSecond
        case kilobitsPerSecond
        case megabitsPerSecond
        case gigabitsPerSecond
        case rpm
        case milliseconds
        case seconds
    }

    private struct QuantityField {
        let key: String
        let defaultUnit: QuantityUnit

        init(_ key: String, defaultUnit: QuantityUnit) {
            self.key = key
            self.defaultUnit = defaultUnit
        }
    }

    private static func decodedObject(from data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            return dictionary
        }

        var format = PropertyListSerialization.PropertyListFormat.xml
        if let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ), let dictionary = object as? [String: Any] {
            return dictionary
        }

        throw NetworkSpeedTestError.invalidOutput
    }

    private static func quantity(
        in object: [String: Any],
        fields: [QuantityField],
        kind: QuantityKind,
        maximum: Double
    ) throws -> Double {
        for field in fields {
            guard let rawValue = object[field.key] else { continue }
            let value = try numericValue(
                rawValue,
                defaultUnit: field.defaultUnit,
                kind: kind
            )
            guard value.isFinite, value >= 0, value <= maximum else {
                throw NetworkSpeedTestError.invalidOutput
            }
            return value
        }
        throw NetworkSpeedTestError.invalidOutput
    }

    private static func numericValue(
        _ rawValue: Any,
        defaultUnit: QuantityUnit,
        kind: QuantityKind
    ) throws -> Double {
        if rawValue is Bool {
            throw NetworkSpeedTestError.invalidOutput
        }

        if let number = rawValue as? NSNumber {
            return try converted(
                number.doubleValue,
                unit: defaultUnit,
                kind: kind
            )
        }

        guard let string = rawValue as? String else {
            throw NetworkSpeedTestError.invalidOutput
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NetworkSpeedTestError.invalidOutput
        }

        let numericCharacters = CharacterSet(charactersIn: "+-0123456789.eE")
        var numericEnd = trimmed.startIndex
        while numericEnd < trimmed.endIndex,
              trimmed[numericEnd].unicodeScalars.allSatisfy({ numericCharacters.contains($0) }) {
            numericEnd = trimmed.index(after: numericEnd)
        }

        let numberText = String(trimmed[..<numericEnd])
        let rawUnitText = String(trimmed[numericEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if case .throughput = kind, rawUnitText.contains("B") {
            throw NetworkSpeedTestError.invalidOutput
        }
        let unitText = rawUnitText
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard let value = Double(numberText) else {
            throw NetworkSpeedTestError.invalidOutput
        }

        let unit = try parsedUnit(unitText, defaultUnit: defaultUnit, kind: kind)
        return try converted(value, unit: unit, kind: kind)
    }

    private static func parsedUnit(
        _ text: String,
        defaultUnit: QuantityUnit,
        kind: QuantityKind
    ) throws -> QuantityUnit {
        guard !text.isEmpty else { return defaultUnit }

        switch kind {
        case .throughput:
            switch text {
            case "bps", "bit/s", "bits/s", "bitpersecond", "bitspersecond":
                return .bitsPerSecond
            case "kbps", "kbit/s", "kilobitspersecond":
                return .kilobitsPerSecond
            case "mbps", "mbit/s", "megabitspersecond":
                return .megabitsPerSecond
            case "gbps", "gbit/s", "gigabitspersecond":
                return .gigabitsPerSecond
            default:
                throw NetworkSpeedTestError.invalidOutput
            }
        case .responsiveness:
            guard text == "rpm" else { throw NetworkSpeedTestError.invalidOutput }
            return .rpm
        case .latency:
            switch text {
            case "ms", "millisecond", "milliseconds":
                return .milliseconds
            case "s", "sec", "secs", "second", "seconds":
                return .seconds
            default:
                throw NetworkSpeedTestError.invalidOutput
            }
        }
    }

    private static func converted(
        _ value: Double,
        unit: QuantityUnit,
        kind: QuantityKind
    ) throws -> Double {
        guard value.isFinite else { throw NetworkSpeedTestError.invalidOutput }

        switch (kind, unit) {
        case (.throughput, .bitsPerSecond):
            return value / 1_000_000
        case (.throughput, .kilobitsPerSecond):
            return value / 1_000
        case (.throughput, .megabitsPerSecond):
            return value
        case (.throughput, .gigabitsPerSecond):
            return value * 1_000
        case (.responsiveness, .rpm):
            return value
        case (.latency, .milliseconds):
            return value
        case (.latency, .seconds):
            return value * 1_000
        default:
            throw NetworkSpeedTestError.invalidOutput
        }
    }

    private static func interfaceName(in object: [String: Any]) throws -> String {
        let value = object["interface_name"] ?? object["interface"]
        guard let rawName = value as? String else {
            throw NetworkSpeedTestError.invalidOutput
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        let baseCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_-")
        )
        guard !name.isEmpty,
              name.count <= 64,
              components.count <= 2,
              let firstScalar = components.first?.unicodeScalars.first,
              CharacterSet.letters.contains(firstScalar),
              components.first?.unicodeScalars.allSatisfy({ baseCharacters.contains($0) }) == true,
              components.count == 1
                || components[1].unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) })
                    && !components[1].isEmpty else {
            throw NetworkSpeedTestError.invalidOutput
        }
        return name
    }

    private static func transferredBytes(in object: [String: Any]) -> UInt64? {
        let fieldPairs = [
            ("downlink_bytes_transferred", "uplink_bytes_transferred"),
            ("dl_bytes_transferred", "ul_bytes_transferred")
        ]

        for (downloadKey, uploadKey) in fieldPairs {
            guard let rawDownload = object[downloadKey],
                  let rawUpload = object[uploadKey] else {
                continue
            }
            guard let download = safeUnsignedInteger(rawDownload),
                  let upload = safeUnsignedInteger(rawUpload) else {
                return nil
            }
            let (total, overflowed) = download.addingReportingOverflow(upload)
            return overflowed ? nil : total
        }
        return nil
    }

    private static func safeUnsignedInteger(_ rawValue: Any) -> UInt64? {
        if rawValue is Bool {
            return nil
        }

        let text: String
        if let number = rawValue as? NSNumber {
            text = number.stringValue
        } else if let string = rawValue as? String {
            text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }

        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) else {
            return nil
        }
        return UInt64(text)
    }

    private static func validateOutputSize(
        _ output: NetworkQualityCommandOutput,
        limit: Int
    ) throws {
        guard limit >= 0,
              output.standardOutput.count <= limit,
              output.standardError.count <= limit,
              output.standardOutput.count <= limit - output.standardError.count else {
            throw NetworkSpeedTestError.outputTooLarge
        }
    }

    private static func indicatesServiceUnavailable(
        _ output: NetworkQualityCommandOutput
    ) -> Bool {
        serviceUnavailableEnvelope(in: output.standardOutput)
            || serviceUnavailableEnvelope(in: output.standardError)
    }

    private static func serviceUnavailableEnvelope(in data: Data) -> Bool {
        guard !data.isEmpty,
              let object = try? decodedObject(from: data) else {
            return false
        }

        if isServiceUnavailableEnvelope(object) {
            return true
        }
        if let nestedError = object["error"] as? [String: Any] {
            return isServiceUnavailableEnvelope(nestedError)
        }
        return false
    }

    private static func isServiceUnavailableEnvelope(_ object: [String: Any]) -> Bool {
        let rawDomain = object["domain"] ?? object["error_domain"]
        let rawCode = object["code"] ?? object["error_code"]
        guard let domain = rawDomain as? String,
              domain.trimmingCharacters(in: .whitespacesAndNewlines)
                == "NetworkQualityErrorDomain",
              let rawCode else {
            return false
        }

        if let number = rawCode as? NSNumber, !(rawCode is Bool) {
            return number.doubleValue == 1_003
        }
        if let string = rawCode as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) == 1_003
        }
        return false
    }

    private static func indicatesOffline(_ output: NetworkQualityCommandOutput) -> Bool {
        if errorCodeIndicatesOffline(output.standardOutput)
            || errorCodeIndicatesOffline(output.standardError) {
            return true
        }

        let inspectedData = output.standardOutput + output.standardError
        let text = String(decoding: inspectedData, as: UTF8.self).lowercased()
        return [
            "appears to be offline",
            "not connected to the internet",
            "network is unreachable",
            "could not resolve host",
            "cannot connect to the internet"
        ].contains { text.contains($0) }
    }

    private static func errorCodeIndicatesOffline(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let object = try? decodedObject(from: data),
              let rawCode = object["error_code"] else {
            return false
        }

        if let number = rawCode as? NSNumber, !(rawCode is Bool) {
            return number.intValue == -1_009
        }
        if let string = rawCode as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) == -1_009
        }
        return false
    }
}

enum NetworkQualityOutputStream: Hashable, Sendable {
    case standardOutput
    case standardError
}

struct NetworkQualityOutputSnapshot: Sendable {
    let standardOutput: Data
    let standardError: Data
    let didExceedLimit: Bool
    let didFailReading: Bool
}

final class NetworkQualityOutputAccumulator: Sendable {
    private struct State: Sendable {
        var standardOutput = Data()
        var standardError = Data()
        var didExceedLimit = false
        var didFailReading = false
    }

    private let limit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    @discardableResult
    func append(_ data: Data, to stream: NetworkQualityOutputStream) -> Bool {
        state.withLock { state in
            guard !data.isEmpty else { return !state.didExceedLimit }
            let streamCount = stream == .standardOutput
                ? state.standardOutput.count
                : state.standardError.count
            let totalCount = state.standardOutput.count + state.standardError.count
            let available = min(limit - streamCount, limit - totalCount)
            let acceptedCount = max(0, min(data.count, available))

            if acceptedCount < data.count {
                state.didExceedLimit = true
            }
            guard acceptedCount > 0 else { return !state.didExceedLimit }

            switch stream {
            case .standardOutput:
                state.standardOutput.append(contentsOf: data.prefix(acceptedCount))
            case .standardError:
                state.standardError.append(contentsOf: data.prefix(acceptedCount))
            }
            return !state.didExceedLimit
        }
    }

    func markReadFailure() {
        state.withLock { $0.didFailReading = true }
    }

    func snapshot() -> NetworkQualityOutputSnapshot {
        state.withLock { state in
            NetworkQualityOutputSnapshot(
                standardOutput: state.standardOutput,
                standardError: state.standardError,
                didExceedLimit: state.didExceedLimit,
                didFailReading: state.didFailReading
            )
        }
    }
}

private actor NetworkQualityIODrainCompletion {
    private var isFinished = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        if isFinished { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

enum NetworkQualityPipeDrainer {
    static func drain(
        _ fileHandle: FileHandle,
        stream outputStream: NetworkQualityOutputStream,
        into accumulator: NetworkQualityOutputAccumulator
    ) async {
        let completion = NetworkQualityIODrainCompletion()
        let queue = DispatchQueue(
            label: "StorageCleanerMac.NetworkQualityPipeDrainer",
            qos: .utility
        )
        let channel = DispatchIO(
            type: .stream,
            fileDescriptor: fileHandle.fileDescriptor,
            queue: queue
        ) { error in
            if error != 0, error != ECANCELED {
                accumulator.markReadFailure()
            }
            try? fileHandle.close()
            Task { await completion.finish() }
        }
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: 64 * 1_024)
        channel.read(offset: 0, length: Int.max, queue: queue) { done, dispatchData, error in
            if let dispatchData, !dispatchData.isEmpty {
                let remainsWithinLimit = accumulator.append(
                    Data(dispatchData),
                    to: outputStream
                )
                if !remainsWithinLimit {
                    channel.close(flags: .stop)
                    return
                }
            }

            if error != 0, error != ECANCELED {
                accumulator.markReadFailure()
            }
            if done {
                channel.close()
            }
        }

        await withTaskCancellationHandler {
            await completion.wait()
        } onCancel: {
            channel.close(flags: .stop)
        }
    }
}

actor NetworkQualityDrainMonitor {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }

    private var finishedStreams = Set<NetworkQualityOutputStream>()
    private var waiters = [UUID: Waiter]()

    func markFinished(_ stream: NetworkQualityOutputStream) {
        finishedStreams.insert(stream)
        guard isComplete else { return }

        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    func wait(
        timeout: Duration,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) async -> Bool {
        if isComplete { return true }
        guard timeout > .zero else { return false }

        let identifier = UUID()
        return await withCheckedContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                do {
                    try await sleep(timeout)
                } catch {
                    await self?.expire(identifier)
                    return
                }
                await self?.expire(identifier)
            }
            waiters[identifier] = Waiter(
                continuation: continuation,
                timeoutTask: timeoutTask
            )
        }
    }

    private var isComplete: Bool {
        finishedStreams.contains(.standardOutput)
            && finishedStreams.contains(.standardError)
    }

    private func expire(_ identifier: UUID) {
        guard let waiter = waiters.removeValue(forKey: identifier) else { return }
        waiter.continuation.resume(returning: false)
    }
}

enum NetworkQualityTerminationSignal: Hashable, Sendable {
    case interrupt
    case terminate
    case kill

    var systemValue: Int32 {
        switch self {
        case .interrupt: SIGINT
        case .terminate: SIGTERM
        case .kill: SIGKILL
        }
    }
}

enum NetworkQualitySignalResult: Equatable, Sendable {
    case sent
    case alreadyExited
    case identityMismatch
    case failed
}

enum NetworkQualityProcessPresence: Equatable, Sendable {
    case running
    case alreadyExited
    case identityMismatch
    case failed
}

struct NetworkQualityProcessIdentity: Equatable, Hashable, Sendable {
    let processID: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

protocol NetworkQualityProcessIdentityReading: Sendable {
    func identity(for processID: pid_t) async -> NetworkQualityProcessIdentity?
}

struct NetworkQualityBSDProcessIdentityReader: NetworkQualityProcessIdentityReading {
    func identity(for processID: pid_t) async -> NetworkQualityProcessIdentity? {
        guard processID > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard result == expectedSize, info.pbi_pid == UInt32(processID) else { return nil }
        return NetworkQualityProcessIdentity(
            processID: processID,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }
}

enum NetworkQualityProcessSystemCallResult: Equatable, Sendable {
    case success
    case failure(Int32)
}

protocol NetworkQualityProcessSystemCalling: Sendable {
    func send(processID: pid_t, signal: Int32) async -> NetworkQualityProcessSystemCallResult
}

struct NetworkQualityDarwinProcessSystemCalls: NetworkQualityProcessSystemCalling {
    func send(processID: pid_t, signal: Int32) async -> NetworkQualityProcessSystemCallResult {
        errno = 0
        guard Darwin.kill(processID, signal) == 0 else {
            return .failure(errno)
        }
        return .success
    }
}

protocol NetworkQualityProcessControlling: Sendable {
    func presence() async -> NetworkQualityProcessPresence
    func send(_ signal: NetworkQualityTerminationSignal) async -> NetworkQualitySignalResult
}

struct NetworkQualityVerifiedProcessControl: NetworkQualityProcessControlling {
    private let expectedIdentity: NetworkQualityProcessIdentity
    private let identityReader: any NetworkQualityProcessIdentityReading
    private let systemCalls: any NetworkQualityProcessSystemCalling

    init(
        expectedIdentity: NetworkQualityProcessIdentity,
        identityReader: any NetworkQualityProcessIdentityReading,
        systemCalls: any NetworkQualityProcessSystemCalling
    ) {
        self.expectedIdentity = expectedIdentity
        self.identityReader = identityReader
        self.systemCalls = systemCalls
    }

    func presence() async -> NetworkQualityProcessPresence {
        if let currentIdentity = await identityReader.identity(
            for: expectedIdentity.processID
        ) {
            return currentIdentity == expectedIdentity ? .running : .identityMismatch
        }

        switch await systemCalls.send(processID: expectedIdentity.processID, signal: 0) {
        case .success:
            return .failed
        case let .failure(errorCode) where errorCode == ESRCH:
            return .alreadyExited
        case .failure:
            return .failed
        }
    }

    func send(_ signal: NetworkQualityTerminationSignal) async -> NetworkQualitySignalResult {
        switch await presence() {
        case .alreadyExited:
            return .alreadyExited
        case .identityMismatch:
            return .identityMismatch
        case .failed:
            return .failed
        case .running:
            break
        }

        switch await systemCalls.send(
            processID: expectedIdentity.processID,
            signal: signal.systemValue
        ) {
        case .success:
            return .sent
        case let .failure(errorCode) where errorCode == ESRCH:
            return .alreadyExited
        case .failure:
            return .failed
        }
    }
}

private actor NetworkQualityFoundationProcessOwner {
    let process: Process

    init(process: Process) {
        self.process = process
    }
}

private struct NetworkQualityOwnedProcessControl: NetworkQualityProcessControlling {
    private let owner: NetworkQualityFoundationProcessOwner
    private let verifiedControl: NetworkQualityVerifiedProcessControl

    init(
        owner: NetworkQualityFoundationProcessOwner,
        verifiedControl: NetworkQualityVerifiedProcessControl
    ) {
        self.owner = owner
        self.verifiedControl = verifiedControl
    }

    func presence() async -> NetworkQualityProcessPresence {
        _ = owner
        return await verifiedControl.presence()
    }

    func send(_ signal: NetworkQualityTerminationSignal) async -> NetworkQualitySignalResult {
        _ = owner
        return await verifiedControl.send(signal)
    }
}

private struct NetworkQualityUnverifiedProcessControl: NetworkQualityProcessControlling {
    private let owner: NetworkQualityFoundationProcessOwner

    init(owner: NetworkQualityFoundationProcessOwner) {
        self.owner = owner
    }

    func presence() async -> NetworkQualityProcessPresence {
        _ = owner
        return .failed
    }

    func send(_ signal: NetworkQualityTerminationSignal) async -> NetworkQualitySignalResult {
        _ = owner
        return .failed
    }
}

struct NetworkQualityLaunchedProcess: Sendable {
    let handle: any NetworkQualityProcessControlling
    let standardOutput: FileHandle
    let standardError: FileHandle
    let identityVerified: Bool
}

protocol NetworkQualityProcessLaunching: Sendable {
    func launch(
        _ command: NetworkQualityCommand,
        operationID: UUID,
        terminationHandler: @escaping @Sendable (Int32) -> Void
    ) async throws -> NetworkQualityLaunchedProcess
}

struct NetworkQualityFoundationProcessLauncher: NetworkQualityProcessLaunching {
    private let identityReader: any NetworkQualityProcessIdentityReading
    private let systemCalls: any NetworkQualityProcessSystemCalling
    private let startProcess: @Sendable (Process) throws -> Void

    init(
        identityReader: any NetworkQualityProcessIdentityReading,
        systemCalls: any NetworkQualityProcessSystemCalling,
        startProcess: @escaping @Sendable (Process) throws -> Void = { process in
            try process.run()
        }
    ) {
        self.identityReader = identityReader
        self.systemCalls = systemCalls
        self.startProcess = startProcess
    }

    func launch(
        _ command: NetworkQualityCommand,
        operationID: UUID,
        terminationHandler: @escaping @Sendable (Int32) -> Void
    ) async throws -> NetworkQualityLaunchedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        process.terminationHandler = { finishedProcess in
            terminationHandler(finishedProcess.terminationStatus)
        }

        do {
            try Task.checkCancellation()
            try startProcess(process)
        } catch is CancellationError {
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForWriting.close()
            try? standardOutputPipe.fileHandleForReading.close()
            try? standardErrorPipe.fileHandleForReading.close()
            throw CancellationError()
        } catch {
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForWriting.close()
            try? standardOutputPipe.fileHandleForReading.close()
            try? standardErrorPipe.fileHandleForReading.close()
            throw NetworkSpeedTestError.failed
        }

        try? standardOutputPipe.fileHandleForWriting.close()
        try? standardErrorPipe.fileHandleForWriting.close()
        let owner = NetworkQualityFoundationProcessOwner(process: process)
        let processID = process.processIdentifier

        let handle: any NetworkQualityProcessControlling
        let identityVerified: Bool
        if let identity = await identityReader.identity(for: processID) {
            let verifiedControl = NetworkQualityVerifiedProcessControl(
                expectedIdentity: identity,
                identityReader: identityReader,
                systemCalls: systemCalls
            )
            handle = NetworkQualityOwnedProcessControl(
                owner: owner,
                verifiedControl: verifiedControl
            )
            identityVerified = true
        } else {
            handle = NetworkQualityUnverifiedProcessControl(owner: owner)
            identityVerified = false
        }

        return NetworkQualityLaunchedProcess(
            handle: handle,
            standardOutput: standardOutputPipe.fileHandleForReading,
            standardError: standardErrorPipe.fileHandleForReading,
            identityVerified: identityVerified
        )
    }
}

enum NetworkQualityTerminationOutcome: Equatable, Sendable {
    case interrupted
    case signalFailed
    case identityMismatch
    case reapTimedOut
}

struct NetworkQualityTerminationSequence: Sendable {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    let interruptGrace: Duration
    let terminateGrace: Duration
    let killGrace: Duration
    let reapGrace: Duration
    let sleep: Sleep

    init(
        interruptGrace: Duration = .seconds(1),
        terminateGrace: Duration = .milliseconds(250),
        killGrace: Duration = .seconds(1),
        reapGrace: Duration = .seconds(1),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.interruptGrace = interruptGrace
        self.terminateGrace = terminateGrace
        self.killGrace = killGrace
        self.reapGrace = reapGrace
        self.sleep = sleep
    }

    func stop(_ process: any NetworkQualityProcessControlling) async -> NetworkQualityTerminationOutcome {
        switch await process.send(.interrupt) {
        case .sent:
            break
        case .alreadyExited:
            return await waitForTerminationHandler()
        case .identityMismatch:
            return .identityMismatch
        case .failed:
            return .signalFailed
        }
        guard await pause(interruptGrace) else { return .interrupted }

        switch await process.send(.terminate) {
        case .sent:
            break
        case .alreadyExited:
            return await waitForTerminationHandler()
        case .identityMismatch:
            return .identityMismatch
        case .failed:
            return .signalFailed
        }
        guard await pause(terminateGrace) else { return .interrupted }

        switch await process.send(.kill) {
        case .sent:
            break
        case .alreadyExited:
            return await waitForTerminationHandler()
        case .identityMismatch:
            return .identityMismatch
        case .failed:
            return .signalFailed
        }
        guard await pause(killGrace) else { return .interrupted }

        switch await process.presence() {
        case .identityMismatch:
            return .identityMismatch
        case .failed:
            return .signalFailed
        case .running, .alreadyExited:
            return .reapTimedOut
        }
    }

    private func waitForTerminationHandler() async -> NetworkQualityTerminationOutcome {
        guard await pause(reapGrace) else { return .interrupted }
        return .reapTimedOut
    }

    private func pause(_ duration: Duration) async -> Bool {
        do {
            try await sleep(duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

actor NetworkQualityProcessReaper {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct Entry {
        let handle: any NetworkQualityProcessControlling
        var cleanupTask: Task<Void, Never>?
    }

    private let retryInterval: Duration
    private let sleep: Sleep
    private var entries = [UUID: Entry]()
    private var terminatedBeforeRegistration = Set<UUID>()
    private var releaseWaiters = [UUID: [CheckedContinuation<Void, Never>]]()

    init(
        retryInterval: Duration = .seconds(1),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.retryInterval = retryInterval
        self.sleep = sleep
    }

    func register(
        operationID: UUID,
        handle: any NetworkQualityProcessControlling
    ) {
        if terminatedBeforeRegistration.remove(operationID) != nil {
            return
        }
        entries[operationID] = Entry(handle: handle, cleanupTask: nil)
    }

    func terminationObserved(operationID: UUID) {
        guard let entry = entries.removeValue(forKey: operationID) else {
            terminatedBeforeRegistration.insert(operationID)
            resumeReleaseWaiters(operationID: operationID)
            return
        }
        entry.cleanupTask?.cancel()
        resumeReleaseWaiters(operationID: operationID)
    }

    func requestCleanup(operationID: UUID) {
        guard var entry = entries[operationID], entry.cleanupTask == nil else { return }
        let handle = entry.handle
        entry.cleanupTask = Task { [self] in
            await cleanupLoop(operationID: operationID, handle: handle)
        }
        entries[operationID] = entry
    }

    func retainedProcessCount() -> Int {
        entries.count
    }

    func waitUntilReleased(operationID: UUID) async {
        await withCheckedContinuation { continuation in
            guard entries[operationID] != nil else {
                continuation.resume()
                return
            }
            releaseWaiters[operationID, default: []].append(continuation)
        }
    }

    private func resumeReleaseWaiters(operationID: UUID) {
        let waiters = releaseWaiters.removeValue(forKey: operationID) ?? []
        waiters.forEach { $0.resume() }
    }

    private func cleanupLoop(
        operationID: UUID,
        handle: any NetworkQualityProcessControlling
    ) async {
        while entries[operationID] != nil, !Task.isCancelled {
            let signalResult = await handle.send(.kill)
            guard entries[operationID] != nil, !Task.isCancelled else { return }
            if signalResult == .alreadyExited || signalResult == .identityMismatch {
                await waitForTerminationObservation(operationID: operationID)
                return
            }
            do {
                try await sleep(retryInterval)
            } catch {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func waitForTerminationObservation(operationID: UUID) async {
        while entries[operationID] != nil, !Task.isCancelled {
            do {
                try await sleep(retryInterval)
            } catch {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct NetworkQualityProcessConfiguration: Equatable, Sendable {
    let maximumWatchdog: Duration
    let drainCompletionGrace: Duration
    let drainCancellationGrace: Duration

    static let production = Self(
        maximumWatchdog: .seconds(25),
        drainCompletionGrace: .seconds(1),
        drainCancellationGrace: .seconds(1)
    )

    static func testing(
        maximumWatchdog: Duration = .seconds(25),
        drainCompletionGrace: Duration = .milliseconds(100),
        drainCancellationGrace: Duration = .milliseconds(100)
    ) -> Self {
        Self(
            maximumWatchdog: maximumWatchdog,
            drainCompletionGrace: drainCompletionGrace,
            drainCancellationGrace: drainCancellationGrace
        )
    }
}

struct NetworkQualityProcessRunner: NetworkQualityRunning {
    typealias Sleep = NetworkQualityTerminationSequence.Sleep

    private let launcher: any NetworkQualityProcessLaunching
    private let reaper: NetworkQualityProcessReaper
    private let configuration: NetworkQualityProcessConfiguration
    private let terminationSequence: NetworkQualityTerminationSequence
    private let sleep: Sleep
    private let drainSleep: Sleep

    init() {
        let identityReader = NetworkQualityBSDProcessIdentityReader()
        let systemCalls = NetworkQualityDarwinProcessSystemCalls()
        launcher = NetworkQualityFoundationProcessLauncher(
            identityReader: identityReader,
            systemCalls: systemCalls
        )
        reaper = NetworkQualityProcessReaper()
        configuration = .production
        terminationSequence = NetworkQualityTerminationSequence()
        sleep = { @Sendable duration in try await Task.sleep(for: duration) }
        drainSleep = { @Sendable duration in try await Task.sleep(for: duration) }
    }

    init(
        launcher: any NetworkQualityProcessLaunching,
        reaper: NetworkQualityProcessReaper,
        configuration: NetworkQualityProcessConfiguration,
        terminationSequence: NetworkQualityTerminationSequence = NetworkQualityTerminationSequence(),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        drainSleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.launcher = launcher
        self.reaper = reaper
        self.configuration = configuration
        self.terminationSequence = terminationSequence
        self.sleep = sleep
        self.drainSleep = drainSleep
    }

    func run(_ command: NetworkQualityCommand) async throws -> NetworkQualityCommandOutput {
        let execution = NetworkQualityProcessExecution(
            launcher: launcher,
            reaper: reaper,
            configuration: configuration,
            terminationSequence: terminationSequence,
            sleep: sleep,
            drainSleep: drainSleep
        )
        return try await withTaskCancellationHandler {
            try await execution.execute(command)
        } onCancel: {
            Task {
                await execution.requestCancellation()
            }
        }
    }
}

private enum NetworkQualityStopReason: Sendable {
    case timedOut
    case cancelled
}

private enum NetworkQualityProcessLifecycleFailure: Sendable {
    case identityUnavailable
    case signalFailed
    case identityMismatch
    case reapTimedOut
}

private enum NetworkQualityProcessExitOutcome: Sendable {
    case exited(Int32)
    case lifecycleFailure(NetworkQualityProcessLifecycleFailure)
}

private actor NetworkQualityProcessExitMonitor {
    private var outcome: NetworkQualityProcessExitOutcome?
    private var waiters = [CheckedContinuation<NetworkQualityProcessExitOutcome, Never>]()

    func wait() async -> NetworkQualityProcessExitOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish(_ outcome: NetworkQualityProcessExitOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: outcome) }
    }
}

actor NetworkQualityProcessExecution {
    private let launcher: any NetworkQualityProcessLaunching
    private let reaper: NetworkQualityProcessReaper
    private let configuration: NetworkQualityProcessConfiguration
    private let terminationSequence: NetworkQualityTerminationSequence
    private let sleep: NetworkQualityProcessRunner.Sleep
    private let drainSleep: NetworkQualityProcessRunner.Sleep

    private var activeOperationID: UUID?
    private var activeHandle: (any NetworkQualityProcessControlling)?
    private var exitMonitor: NetworkQualityProcessExitMonitor?
    private var stopReason: NetworkQualityStopReason?
    private var watchdogTask: Task<Void, Never>?
    private var escalationTask: Task<Void, Never>?

    init(
        launcher: any NetworkQualityProcessLaunching,
        reaper: NetworkQualityProcessReaper,
        configuration: NetworkQualityProcessConfiguration,
        terminationSequence: NetworkQualityTerminationSequence,
        sleep: @escaping NetworkQualityProcessRunner.Sleep,
        drainSleep: @escaping NetworkQualityProcessRunner.Sleep
    ) {
        self.launcher = launcher
        self.reaper = reaper
        self.configuration = configuration
        self.terminationSequence = terminationSequence
        self.sleep = sleep
        self.drainSleep = drainSleep
    }

    func execute(_ command: NetworkQualityCommand) async throws -> NetworkQualityCommandOutput {
        try Task.checkCancellation()
        guard activeOperationID == nil,
              activeHandle == nil,
              command.executablePath == NetworkSpeedTestService.executablePath,
              command.arguments == NetworkSpeedTestService.arguments,
              command.outputByteLimit > 0,
              command.outputByteLimit <= NetworkSpeedTestService.outputByteLimit,
              command.watchdog > .zero,
              configuration.maximumWatchdog > .zero else {
            throw NetworkSpeedTestError.failed
        }

        let operationID = UUID()
        let monitor = NetworkQualityProcessExitMonitor()
        let reaper = self.reaper
        let launched: NetworkQualityLaunchedProcess
        do {
            launched = try await launcher.launch(
                command,
                operationID: operationID
            ) { status in
                Task {
                    await monitor.finish(.exited(status))
                    await reaper.terminationObserved(operationID: operationID)
                }
            }
        } catch is CancellationError {
            throw NetworkSpeedTestError.cancelled
        } catch {
            if Task.isCancelled || stopReason == .cancelled {
                throw NetworkSpeedTestError.cancelled
            }
            throw NetworkSpeedTestError.failed
        }

        await reaper.register(operationID: operationID, handle: launched.handle)
        activeOperationID = operationID
        activeHandle = launched.handle
        exitMonitor = monitor

        let accumulator = NetworkQualityOutputAccumulator(limit: command.outputByteLimit)
        let drainMonitor = NetworkQualityDrainMonitor()
        let outputTask = Task.detached(priority: .utility) {
            await NetworkQualityPipeDrainer.drain(
                launched.standardOutput,
                stream: .standardOutput,
                into: accumulator
            )
            await drainMonitor.markFinished(.standardOutput)
        }
        let errorTask = Task.detached(priority: .utility) {
            await NetworkQualityPipeDrainer.drain(
                launched.standardError,
                stream: .standardError,
                into: accumulator
            )
            await drainMonitor.markFinished(.standardError)
        }

        if !launched.identityVerified {
            await reaper.requestCleanup(operationID: operationID)
            await monitor.finish(.lifecycleFailure(.identityUnavailable))
        } else if Task.isCancelled || stopReason == .cancelled {
            requestStop(.cancelled)
        } else {
            startWatchdog(
                min(command.watchdog, configuration.maximumWatchdog)
            )
        }

        let exitOutcome = await monitor.wait()
        watchdogTask?.cancel()
        escalationTask?.cancel()

        if case .lifecycleFailure = exitOutcome {
            await reaper.requestCleanup(operationID: operationID)
        }
        let drainsCompleted = await Self.finishDraining(
            monitor: drainMonitor,
            outputTask: outputTask,
            errorTask: errorTask,
            completionGrace: configuration.drainCompletionGrace,
            cancellationGrace: configuration.drainCancellationGrace,
            sleep: drainSleep,
            forceCancel: exitOutcome.requiresForcedDrain
        )
        let output = accumulator.snapshot()
        let reason = stopReason

        if !drainsCompleted {
            await reaper.requestCleanup(operationID: operationID)
        }
        clearOperation()

        guard drainsCompleted else {
            throw cleanupPendingError(operationID: operationID)
        }
        if case .lifecycleFailure = exitOutcome {
            throw cleanupPendingError(operationID: operationID)
        }
        if reason == .timedOut {
            throw NetworkSpeedTestError.timedOut
        }
        if reason == .cancelled || Task.isCancelled {
            throw NetworkSpeedTestError.cancelled
        }
        if output.didExceedLimit {
            throw NetworkSpeedTestError.outputTooLarge
        }
        if output.didFailReading {
            throw cleanupPendingError(operationID: operationID)
        }

        guard case let .exited(status) = exitOutcome else {
            throw cleanupPendingError(operationID: operationID)
        }
        return NetworkQualityCommandOutput(
            terminationStatus: status,
            standardOutput: output.standardOutput,
            standardError: output.standardError
        )
    }

    func requestCancellation() {
        requestStop(.cancelled)
    }

    private func cleanupPendingError(
        operationID: UUID
    ) -> NetworkSpeedTestCleanupPendingError {
        NetworkSpeedTestCleanupPendingError(
            context: NetworkQualityCleanupContext(
                operationID: operationID,
                reaper: reaper
            )
        )
    }

    private func startWatchdog(_ watchdog: Duration) {
        let sleep = self.sleep
        watchdogTask = Task { [weak self] in
            do {
                try await sleep(watchdog)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.requestStop(.timedOut)
        }
    }

    private func requestStop(_ reason: NetworkQualityStopReason) {
        if stopReason == nil {
            stopReason = reason
        }
        startEscalationIfPossible()
    }

    private func startEscalationIfPossible() {
        guard escalationTask == nil,
              let handle = activeHandle,
              let operationID = activeOperationID,
              let monitor = exitMonitor else {
            return
        }

        let terminationSequence = self.terminationSequence
        let reaper = self.reaper
        escalationTask = Task {
            let outcome = await terminationSequence.stop(handle)
            switch outcome {
            case .interrupted:
                guard !Task.isCancelled else { return }
                await reaper.requestCleanup(operationID: operationID)
                await monitor.finish(.lifecycleFailure(.signalFailed))
            case .signalFailed:
                await reaper.requestCleanup(operationID: operationID)
                await monitor.finish(.lifecycleFailure(.signalFailed))
            case .identityMismatch:
                await reaper.requestCleanup(operationID: operationID)
                await monitor.finish(.lifecycleFailure(.identityMismatch))
            case .reapTimedOut:
                await reaper.requestCleanup(operationID: operationID)
                await monitor.finish(.lifecycleFailure(.reapTimedOut))
            }
        }
    }

    private func clearOperation() {
        watchdogTask = nil
        escalationTask = nil
        exitMonitor = nil
        activeHandle = nil
        activeOperationID = nil
        stopReason = nil
    }

    private nonisolated static func finishDraining(
        monitor: NetworkQualityDrainMonitor,
        outputTask: Task<Void, Never>,
        errorTask: Task<Void, Never>,
        completionGrace: Duration,
        cancellationGrace: Duration,
        sleep: @escaping NetworkQualityProcessRunner.Sleep,
        forceCancel: Bool
    ) async -> Bool {
        if !forceCancel,
           await monitor.wait(timeout: completionGrace, sleep: sleep) {
            return true
        }

        outputTask.cancel()
        errorTask.cancel()
        return await monitor.wait(timeout: cancellationGrace, sleep: sleep)
    }
}

private extension NetworkQualityProcessExitOutcome {
    var requiresForcedDrain: Bool {
        if case .lifecycleFailure = self { return true }
        return false
    }
}
