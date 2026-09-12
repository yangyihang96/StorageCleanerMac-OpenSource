import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacAcceleratorBenchmarkHistoryRepositoryTests: XCTestCase {
    private var directoryURL: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MacAcceleratorBenchmarkHistoryRepositoryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        fileURL = directoryURL.appendingPathComponent("accelerator-history.json")
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try super.tearDownWithError()
    }

    func testRoundTripIsNewestFirstAndBounded() async throws {
        let repository = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<(MacAcceleratorBenchmarkHistoryRepository.maximumResults + 3) {
            try await repository.save(
                makeResult(startedAt: base.addingTimeInterval(Double(index * 10)))
            )
        }

        let loaded = await repository.load()
        XCTAssertEqual(
            loaded.count,
            MacAcceleratorBenchmarkHistoryRepository.maximumResults
        )
        XCTAssertEqual(
            loaded.map(\.completedAt),
            loaded.map(\.completedAt).sorted {
                ($0 ?? .distantPast) > ($1 ?? .distantPast)
            }
        )
        XCTAssertEqual(loaded.first?.startedAt, base.addingTimeInterval(140))
        XCTAssertTrue(loaded.allSatisfy(\.isComplete))
    }

    func testSavingSameRunReplacesDuplicate() async throws {
        let repository = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        let result = makeResult()

        try await repository.save(result)
        try await repository.save(result)

        let loaded = await repository.load()
        XCTAssertEqual(loaded, [result])
    }

    func testIncompleteResultIsRejectedWithoutReplacingHistory() async throws {
        let repository = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        let valid = makeResult()
        try await repository.save(valid)
        let bytesBefore = try Data(contentsOf: fileURL)
        let incomplete = MacAcceleratorBenchmarkResult(
            workloadVersion: MacAcceleratorBenchmarkResult.protocolVersion,
            startedAt: valid.startedAt,
            completedAt: nil,
            environment: valid.environment,
            preflight: valid.preflight,
            postflight: nil,
            measurements: [],
            failure: .invalidResult
        )

        do {
            try await repository.save(incomplete)
            XCTFail("不完整的加速器跑分不得进入历史")
        } catch {
            XCTAssertEqual(
                error as? MacAcceleratorBenchmarkHistoryRepositoryError,
                .invalidResult
            )
        }

        let loaded = await repository.load()
        XCTAssertEqual(loaded, [valid])
        XCTAssertEqual(try Data(contentsOf: fileURL), bytesBefore)
    }

    func testFutureEnvironmentAndSafetyContractAreRevalidatedOnSaveAndLoad() async throws {
        let repository = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        let valid = makeResult()
        let future = makeResult(
            startedAt: Date().addingTimeInterval(
                MacAcceleratorBenchmarkHistoryRepository.maximumFutureClockSkew + 60
            )
        )
        let invalidEnvironment = replacing(
            valid,
            environment: BenchmarkEnvironmentMetadata(
                architecture: .arm64,
                chipName: "   ",
                activeProcessorCount: valid.environment.activeProcessorCount,
                physicalMemoryBytes: valid.environment.physicalMemoryBytes,
                powerSource: valid.environment.powerSource,
                thermalState: valid.environment.thermalState,
                operatingSystemVersion: valid.environment.operatingSystemVersion,
                appVersion: valid.environment.appVersion,
                appBuild: valid.environment.appBuild
            )
        )
        let invalidPreflight = replacing(
            valid,
            preflight: BenchmarkPreflight(
                capturedAt: valid.preflight.capturedAt,
                powerSource: valid.preflight.powerSource,
                batteryPercent: valid.preflight.batteryPercent,
                lowPowerModeEnabled: valid.preflight.lowPowerModeEnabled,
                thermalState: valid.preflight.thermalState,
                diskReliability: valid.preflight.diskReliability,
                availableDiskBytes: valid.preflight.availableDiskBytes,
                requiredDiskBytes: valid.preflight.requiredDiskBytes,
                warnings: [.lowPowerModeEnabled]
            )
        )
        let validPostflight = try XCTUnwrap(valid.postflight)
        let invalidPostflight = replacing(
            valid,
            postflight: BenchmarkPostflight(
                capturedAt: validPostflight.capturedAt,
                powerSource: validPostflight.powerSource,
                lowPowerModeEnabled: validPostflight.lowPowerModeEnabled,
                thermalState: validPostflight.thermalState,
                diskReliability: validPostflight.diskReliability,
                availableDiskBytes: validPostflight.availableDiskBytes,
                requiredDiskBytes: validPostflight.requiredDiskBytes,
                warnings: [.insufficientDiskCapacity]
            )
        )

        for invalid in [future, invalidEnvironment, invalidPreflight, invalidPostflight] {
            do {
                try await repository.save(invalid)
                XCTFail("未通过重新校验的记录不得保存")
            } catch {
                XCTAssertEqual(
                    error as? MacAcceleratorBenchmarkHistoryRepositoryError,
                    .invalidResult
                )
            }
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try makeEncoder().encode([
            future,
            invalidEnvironment,
            invalidPreflight,
            invalidPostflight,
            valid,
        ]).write(to: fileURL)

        let loaded = await repository.load()
        XCTAssertEqual(loaded, [valid])
    }

    func testTwoRepositoryInstancesDoNotLoseConcurrentRuns() async throws {
        let first = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        let second = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let results = (0..<MacAcceleratorBenchmarkHistoryRepository.maximumResults).map {
            makeResult(startedAt: base.addingTimeInterval(Double($0 * 10)))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, result) in results.enumerated() {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        try await first.save(result)
                    } else {
                        try await second.save(result)
                    }
                }
            }
            try await group.waitForAll()
        }

        let loaded = await first.load()
        XCTAssertEqual(loaded.count, results.count)
        XCTAssertEqual(Set(loaded.map(\.startedAt)), Set(results.map(\.startedAt)))
    }

    func testHistoryDirectoryFileAndSidecarUsePrivatePermissions() async throws {
        let repository = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        try await repository.save(makeResult())

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: directoryURL.path
        )
        let directoryPermissions = try XCTUnwrap(
            directoryAttributes[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)

        for url in [fileURL!, fileURL.appendingPathExtension("lock")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try XCTUnwrap(
                attributes[.posixPermissions] as? NSNumber
            )
            XCTAssertEqual(permissions.intValue & 0o777, 0o600, url.lastPathComponent)
        }
    }

    func testSymlinkedSidecarAndHistoryAreNeverFollowed() async throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let victim = directoryURL.appendingPathComponent("victim.json")
        let victimBytes = Data("private-victim".utf8)
        try victimBytes.write(to: victim)
        let lockURL = fileURL.appendingPathExtension("lock")
        try FileManager.default.createSymbolicLink(
            at: lockURL,
            withDestinationURL: victim
        )
        let repository = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        let result = makeResult()

        do {
            try await repository.save(result)
            XCTFail("sidecar 符号链接必须被 O_NOFOLLOW 拒绝")
        } catch {
            XCTAssertNotNil(
                error as? MacAcceleratorBenchmarkHistoryRepositoryError
            )
        }
        XCTAssertEqual(try Data(contentsOf: victim), victimBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(
            at: fileURL,
            withDestinationURL: victim
        )
        let symlinkedHistory = await repository.load()
        XCTAssertTrue(symlinkedHistory.isEmpty)
        do {
            try await repository.save(result)
            XCTFail("历史符号链接不得被读取或替换")
        } catch {
            XCTAssertEqual(
                error as? MacAcceleratorBenchmarkHistoryRepositoryError,
                .atomicReplacementFailed(EPERM)
            )
        }
        XCTAssertEqual(try Data(contentsOf: victim), victimBytes)
        var status = stat()
        XCTAssertEqual(lstat(fileURL.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFLNK)
    }

    func testSymlinkedStorageDirectoryIsRejectedBeforeCreatingFiles() async throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let realDirectory = directoryURL.appendingPathComponent(
            "real-history",
            isDirectory: true
        )
        let linkedDirectory = directoryURL.appendingPathComponent(
            "linked-history",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: realDirectory
        )
        let linkedStorage = linkedDirectory.appendingPathComponent("history.json")
        let repository = MacAcceleratorBenchmarkHistoryRepository(
            fileURL: linkedStorage
        )

        do {
            try await repository.save(makeResult())
            XCTFail("存储目录为符号链接时必须拒绝")
        } catch {
            XCTAssertNotNil(error)
        }
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(atPath: realDirectory.path))
                .isEmpty
        )
    }

    func testNonRegularAndHardLinkedHistoryFailClosed() async throws {
        try FileManager.default.createDirectory(
            at: fileURL,
            withIntermediateDirectories: true
        )
        var repository = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        var loaded = await repository.load()
        XCTAssertTrue(loaded.isEmpty)
        do {
            try await repository.save(makeResult())
            XCTFail("非普通文件不得被替换")
        } catch {
            XCTAssertEqual(
                error as? MacAcceleratorBenchmarkHistoryRepositoryError,
                .atomicReplacementFailed(EPERM)
            )
        }

        try FileManager.default.removeItem(at: directoryURL)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        repository = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        try await repository.save(makeResult())
        let linkedFile = directoryURL.appendingPathComponent("linked-history.json")
        try FileManager.default.linkItem(at: fileURL, to: linkedFile)
        let bytesBefore = try Data(contentsOf: fileURL)

        loaded = await repository.load()
        XCTAssertTrue(loaded.isEmpty)
        do {
            try await repository.save(
                makeResult(startedAt: Date(timeIntervalSince1970: 1_700_000_100))
            )
            XCTFail("多硬链接历史文件不得被读取或替换")
        } catch {
            XCTAssertEqual(
                error as? MacAcceleratorBenchmarkHistoryRepositoryError,
                .atomicReplacementFailed(EPERM)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), bytesBefore)
        XCTAssertEqual(try Data(contentsOf: linkedFile), bytesBefore)
    }

    func testCorruptAndOversizedFilesFailClosedAndCorruptFileCanRecover() async throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fileURL)
        var repository = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        var loaded = await repository.load()
        XCTAssertTrue(loaded.isEmpty)

        let valid = makeResult()
        try await repository.save(valid)
        loaded = await repository.load()
        XCTAssertEqual(loaded, [valid])

        let oversized = Data(
            repeating: 0x41,
            count: Int(MacAcceleratorBenchmarkHistoryRepository.maximumFileBytes) + 1
        )
        try oversized.write(to: fileURL)
        repository = MacAcceleratorBenchmarkHistoryRepository(fileURL: fileURL)
        loaded = await repository.load()
        XCTAssertTrue(loaded.isEmpty)
    }
}

private extension MacAcceleratorBenchmarkHistoryRepositoryTests {
    func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func replacing(
        _ result: MacAcceleratorBenchmarkResult,
        environment: BenchmarkEnvironmentMetadata? = nil,
        preflight: BenchmarkPreflight? = nil,
        postflight: BenchmarkPostflight? = nil
    ) -> MacAcceleratorBenchmarkResult {
        MacAcceleratorBenchmarkResult(
            workloadVersion: result.workloadVersion,
            startedAt: result.startedAt,
            completedAt: result.completedAt,
            environment: environment ?? result.environment,
            preflight: preflight ?? result.preflight,
            postflight: postflight ?? result.postflight,
            measurements: result.measurements,
            failure: result.failure
        )
    }

    func makeResult(
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> MacAcceleratorBenchmarkResult {
        let requiredBytes = MacAcceleratorBenchmarkService.requiredDiskBytes
        let preflight = BenchmarkPreflight(
            capturedAt: startedAt.addingTimeInterval(1),
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            diskReliability: .verified,
            availableDiskBytes: 100_000_000_000,
            requiredDiskBytes: requiredBytes,
            warnings: []
        )
        let environment = BenchmarkEnvironmentMetadata(
            architecture: .arm64,
            chipName: "Apple Test",
            activeProcessorCount: 10,
            physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
            powerSource: .acPower,
            thermalState: .nominal,
            operatingSystemVersion: "macOS Test",
            appVersion: "1.0",
            appBuild: "1"
        )
        let measurements = MacAcceleratorMetric.allCases.enumerated().map {
            index, metric in
            MacAcceleratorMeasurement(
                metric: metric,
                availability: .measured,
                samples: [99, 100, 101].map { value in
                    BenchmarkComponentSample(
                        value: Double(value + index * 100),
                        elapsedSeconds: 0.25,
                        checksum: UInt64(index + 1)
                    )
                }
            )
        }
        return MacAcceleratorBenchmarkResult(
            workloadVersion: MacAcceleratorBenchmarkResult.protocolVersion,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(3),
            environment: environment,
            preflight: preflight,
            postflight: BenchmarkPostflight(
                capturedAt: startedAt.addingTimeInterval(2),
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: requiredBytes,
                warnings: []
            ),
            measurements: measurements,
            failure: nil
        )
    }
}
