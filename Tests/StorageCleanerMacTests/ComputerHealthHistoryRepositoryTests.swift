import XCTest
@testable import StorageCleanerMac

final class ComputerHealthHistoryRepositoryTests: XCTestCase {
    private var directoryURL: URL!
    private var storageURL: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputerHealthHistoryRepositoryTests-\(UUID().uuidString)")
        storageURL = directoryURL.appendingPathComponent("health-history.json")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try super.tearDownWithError()
    }

    func testSameDaySaveKeepsNewestAndLoadsNewestFirst() async throws {
        let repository = ComputerHealthHistoryRepository(
            storageURL: storageURL,
            calendar: calendar
        )
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let firstDayMorning = entry(date: start, score: 70)
        let secondDay = entry(date: start.addingTimeInterval(86_400), score: 80)
        let firstDayEvening = entry(date: start.addingTimeInterval(3_600), score: 75)

        try await repository.save(firstDayMorning)
        try await repository.save(secondDay)
        try await repository.save(firstDayEvening)
        try await repository.save(firstDayMorning)

        let loaded = await repository.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.recordedAt), [secondDay.recordedAt, firstDayEvening.recordedAt])
        XCTAssertEqual(loaded.map { $0.evaluation.score }, [80, 75])
    }

    func testRepositoryRetainsOnlyLatestNinetyLocalDays() async throws {
        let repository = ComputerHealthHistoryRepository(
            storageURL: storageURL,
            calendar: calendar
        )
        let start = Date(timeIntervalSince1970: 1_780_000_000)

        for dayOffset in 0..<95 {
            try await repository.save(entry(
                date: start.addingTimeInterval(Double(dayOffset) * 86_400),
                score: Double(dayOffset % 100)
            ))
        }

        let loaded = await repository.load()
        XCTAssertEqual(loaded.count, 90)
        XCTAssertEqual(loaded.first?.recordedAt, start.addingTimeInterval(94 * 86_400))
        XCTAssertEqual(loaded.last?.recordedAt, start.addingTimeInterval(5 * 86_400))
    }

    func testSparseEntriesOlderThanNinetyDayWindowAreTrimmed() async throws {
        let repository = ComputerHealthHistoryRepository(
            storageURL: storageURL,
            calendar: calendar
        )
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        try await repository.save(entry(date: start, score: 70))
        try await repository.save(entry(
            date: start.addingTimeInterval(120 * 86_400),
            score: 80
        ))

        let loaded = await repository.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.evaluation.score, 80)
    }

    func testCorruptJSONFallsBackToEmptyAndNextSaveRecoversAtomically() async throws {
        try Data("not-json".utf8).write(to: storageURL)
        let repository = ComputerHealthHistoryRepository(
            storageURL: storageURL,
            calendar: calendar
        )

        let empty = await repository.load()
        XCTAssertTrue(empty.isEmpty)

        let value = entry(date: Date(timeIntervalSince1970: 1_790_000_000), score: 88)
        try await repository.save(value)
        let recovered = await repository.load()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertNoThrow(try JSONDecoder().decode(
            [ComputerHealthHistoryEntry].self,
            from: Data(contentsOf: storageURL)
        ))
        let directoryItems = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(directoryItems.map(\.lastPathComponent), [storageURL.lastPathComponent])
    }

    func testModelVersionsAndDataInsufficientEvidenceArePreserved() async throws {
        let repository = ComputerHealthHistoryRepository(
            storageURL: storageURL,
            calendar: calendar
        )
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let component = HealthComponentEvaluation(
            factor: .capacity,
            availability: .unavailable,
            score: nil,
            evidenceSummary: nil,
            evaluatedAt: date,
            modelVersion: "component-v7"
        )
        let evaluation = ComputerHealthEvaluation(
            score: nil,
            status: .dataInsufficient,
            coverage: 0.4,
            confidence: .init(value: 42, level: .low, modelVersion: "confidence-v8"),
            components: [component],
            evaluatedAt: date,
            modelVersion: "evaluation-v9"
        )
        let value = ComputerHealthHistoryEntry(
            recordedAt: date,
            evaluation: evaluation,
            totalBytes: nil,
            availableForImportantUsageBytes: nil,
            modelVersion: "history-v10"
        )

        try await repository.save(value)
        let history = await repository.load()
        let loaded = try XCTUnwrap(history.first)

        XCTAssertNil(loaded.evaluation.score)
        XCTAssertNil(loaded.totalBytes)
        XCTAssertEqual(loaded.modelVersion, "history-v10")
        XCTAssertEqual(loaded.evaluation.modelVersion, "evaluation-v9")
        XCTAssertEqual(loaded.evaluation.confidence.modelVersion, "confidence-v8")
        XCTAssertEqual(loaded.evaluation.components.first?.modelVersion, "component-v7")
    }

    func testDiskRemainingLifePercentPersistsAndRejectsInvalidValues() async throws {
        let repository = ComputerHealthHistoryRepository(
            storageURL: storageURL,
            calendar: calendar
        )
        let valid = entry(date: Date(timeIntervalSince1970: 1_790_000_000), score: 88)
        try await repository.save(valid)
        let initiallyLoaded = await repository.load()
        XCTAssertEqual(initiallyLoaded.first?.diskRemainingLifePercent, 94)

        let invalid = ComputerHealthHistoryEntry(
            recordedAt: valid.recordedAt.addingTimeInterval(60),
            evaluation: valid.evaluation,
            diskRemainingLifePercent: 101
        )
        do {
            try await repository.save(invalid)
            XCTFail("Expected invalid disk life percentage to be rejected")
        } catch let error as ComputerHealthHistoryRepositoryError {
            XCTAssertEqual(error, .invalidEntry)
        }
        let loadedAfterRejection = await repository.load()
        XCTAssertEqual(loadedAfterRejection.first?.diskRemainingLifePercent, 94)
    }

    func testEncodedHistoryStripsFreeTextThatCouldContainPrivateData() async throws {
        let repository = ComputerHealthHistoryRepository(
            storageURL: storageURL,
            calendar: calendar
        )
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let privateTokens = [
            "SecretProcessName",
            "/Users/private/Documents/report.ips",
            "private.example.com",
            "203.0.113.42",
            "DISK-SERIAL-ABC123",
            "diagnostic report body"
        ]
        let component = HealthComponentEvaluation(
            factor: .stability,
            availability: .available,
            score: 60,
            evidenceSummary: privateTokens.joined(separator: " | "),
            evaluatedAt: date,
            modelVersion: ComputerHealthEvaluation.currentModelVersion
        )
        let evaluation = ComputerHealthEvaluation(
            score: 60,
            status: .attention,
            coverage: 1,
            confidence: .init(value: 80, level: .high, modelVersion: "health-confidence-v1"),
            components: [component],
            evaluatedAt: date
        )
        try await repository.save(ComputerHealthHistoryEntry(
            recordedAt: date,
            evaluation: evaluation,
            totalBytes: 1_000,
            availableForImportantUsageBytes: 300
        ))

        let encoded = String(decoding: try Data(contentsOf: storageURL), as: UTF8.self)
        for token in privateTokens {
            XCTAssertFalse(encoded.contains(token), "persisted private token: \(token)")
        }
        let history = await repository.load()
        XCTAssertNil(history.first?.evaluation.components.first?.evidenceSummary)
    }

    func testInvalidNonFiniteEntryIsRejectedWithoutReplacingHistory() async throws {
        let repository = ComputerHealthHistoryRepository(
            storageURL: storageURL,
            calendar: calendar
        )
        let valid = entry(date: Date(timeIntervalSince1970: 1_790_000_000), score: 80)
        try await repository.save(valid)
        let invalid = entry(
            date: Date(timeIntervalSinceReferenceDate: .infinity),
            score: .nan
        )

        do {
            try await repository.save(invalid)
            XCTFail("Expected invalid history entry to be rejected")
        } catch let error as ComputerHealthHistoryRepositoryError {
            XCTAssertEqual(error, .invalidEntry)
        }
        let history = await repository.load()
        XCTAssertEqual(history.count, 1)
    }

    private func entry(date: Date, score: Double) -> ComputerHealthHistoryEntry {
        let component = HealthComponentEvaluation(
            factor: .capacity,
            availability: .available,
            score: score,
            evidenceSummary: "safe transient explanation",
            evaluatedAt: date,
            modelVersion: ComputerHealthEvaluation.currentModelVersion
        )
        let evaluation = ComputerHealthEvaluation(
            score: score,
            status: score >= 85 ? .healthy : .attention,
            coverage: 1,
            confidence: .init(value: 80, level: .high, modelVersion: "health-confidence-v1"),
            components: [component],
            evaluatedAt: date
        )
        return ComputerHealthHistoryEntry(
            recordedAt: date,
            evaluation: evaluation,
            totalBytes: 1_000,
            availableForImportantUsageBytes: 300,
            diskRemainingLifePercent: 94,
            maximumCapacityPercent: 95,
            batteryCycleCount: 100
        )
    }
}
