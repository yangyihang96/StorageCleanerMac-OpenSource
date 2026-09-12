import Darwin
import Foundation

protocol NetworkSpeedTestResultPersisting: Sendable {
    func load() async -> NetworkSpeedTestResult?
    func save(_ result: NetworkSpeedTestResult) async throws
}

enum NetworkSpeedTestResultRepositoryError: Error, Equatable {
    case invalidResult
    case invalidStorage
    case oversizedData
}

actor NetworkSpeedTestResultRepository: NetworkSpeedTestResultPersisting {
    static let maximumFileBytes = 64 * 1_024
    static let futureDateTolerance: TimeInterval = 24 * 60 * 60
    static let defaultStorageURL: URL = {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("network-speed-last-result.json", isDirectory: false)
    }()

    private let storageURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        storageURL: URL = NetworkSpeedTestResultRepository.defaultStorageURL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storageURL = storageURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        decoder = JSONDecoder()
    }

    func load() async -> NetworkSpeedTestResult? {
        try? loadValidatedResult()
    }

    func save(_ result: NetworkSpeedTestResult) async throws {
        guard Self.isValid(result, referenceDate: now()) else {
            throw NetworkSpeedTestResultRepositoryError.invalidResult
        }

        try validateWritableStoragePath()

        if let existing = try? loadValidatedResult(),
           existing.testedAt > result.testedAt {
            return
        }

        let data = try encoder.encode(result)
        guard data.count <= Self.maximumFileBytes else {
            throw NetworkSpeedTestResultRepositoryError.oversizedData
        }

        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: storageURL, options: [.atomic])
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageURL.path
        )
    }

    private func validateWritableStoragePath() throws {
        let status = storageURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            var metadata = stat()
            return lstat(path, &metadata) == 0
                ? (metadata.st_mode & S_IFMT == S_IFREG ? 0 : 1)
                : (errno == ENOENT ? 0 : 1)
        }
        guard status == 0 else {
            throw NetworkSpeedTestResultRepositoryError.invalidStorage
        }
    }

    private func loadValidatedResult() throws -> NetworkSpeedTestResult {
        let data = try readStorageData()
        guard !data.isEmpty, data.count <= Self.maximumFileBytes else {
            throw NetworkSpeedTestResultRepositoryError.oversizedData
        }
        let result = try decoder.decode(NetworkSpeedTestResult.self, from: data)
        guard Self.isValid(result, referenceDate: now()) else {
            throw NetworkSpeedTestResultRepositoryError.invalidResult
        }
        return result
    }

    private func readStorageData() throws -> Data {
        let descriptor = storageURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw NetworkSpeedTestResultRepositoryError.invalidStorage
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0,
              metadata.st_size <= Int64(Self.maximumFileBytes) else {
            throw NetworkSpeedTestResultRepositoryError.invalidStorage
        }
        guard let data = try handle.readToEnd() else {
            throw NetworkSpeedTestResultRepositoryError.invalidStorage
        }
        return data
    }

    nonisolated static func isValid(
        _ result: NetworkSpeedTestResult,
        referenceDate: Date
    ) -> Bool {
        guard isFinite(result.downloadMbps, in: 0...1_000_000),
              isFinite(result.uploadMbps, in: 0...1_000_000),
              isFinite(result.idleLatencyMilliseconds, in: 0...86_400_000),
              isFinite(result.durationSeconds, in: 0...3_600),
              isFinite(result.completeness, in: 0...1),
              isFiniteOptional(result.responsivenessRPM, in: 0...10_000_000),
              isFiniteOptional(result.loadedLatencyP50Milliseconds, in: 0...86_400_000),
              isFiniteOptional(result.loadedLatencyP95Milliseconds, in: 0...86_400_000),
              isFiniteOptional(result.jitterMilliseconds, in: 0...86_400_000),
              validInterfaceName(result.interfaceName),
              validMethodVersion(result.methodVersion),
              result.transferredBytes.map({ $0 <= 1_125_899_906_842_624 }) ?? true,
              result.testedAt.timeIntervalSinceReferenceDate.isFinite,
              referenceDate.timeIntervalSinceReferenceDate.isFinite,
              result.testedAt <= referenceDate.addingTimeInterval(futureDateTolerance) else {
            return false
        }

        if let p50 = result.loadedLatencyP50Milliseconds,
           let p95 = result.loadedLatencyP95Milliseconds,
           p95 < p50 {
            return false
        }
        return true
    }

    nonisolated private static func isFinite(
        _ value: Double,
        in range: ClosedRange<Double>
    ) -> Bool {
        value.isFinite && range.contains(value)
    }

    nonisolated private static func isFiniteOptional(
        _ value: Double?,
        in range: ClosedRange<Double>
    ) -> Bool {
        guard let value else { return true }
        return isFinite(value, in: range)
    }

    nonisolated private static func validInterfaceName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        let pattern = #"^[A-Za-z][A-Za-z0-9_-]{0,63}(\.[0-9]{1,5})?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    nonisolated private static func validMethodVersion(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}

actor DiscardingNetworkSpeedTestResultRepository: NetworkSpeedTestResultPersisting {
    func load() async -> NetworkSpeedTestResult? { nil }

    func save(_ result: NetworkSpeedTestResult) async throws {}
}
