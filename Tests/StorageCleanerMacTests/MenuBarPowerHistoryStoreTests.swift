import XCTest
@testable import StorageCleanerMac

final class MenuBarPowerHistoryStoreTests: XCTestCase {
    func testUnifiedMetricHistoryRoundTripsEverySeriesAndKeepsRestartGap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricHistoryStoreTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 300_000)
        let earlier = now.addingTimeInterval(-3_600)
        let store = MetricHistoryStore(url: url)
        let telemetry = MenuBarTelemetryPoint(
            date: earlier,
            cpuTotal: 42,
            cpuUser: 30,
            cpuSystem: 12,
            gpu: 9,
            memory: nil,
            chipTemperature: 54,
            gpuTemperature: 61,
            temperatureReadings: [
                SystemTemperatureReading(zone: .chip, celsius: 54),
                SystemTemperatureReading(zone: .performanceCores, celsius: 57),
                SystemTemperatureReading(zone: .gpu, celsius: 61),
            ],
            fanRPM: 1_800,
            downBytesPerSecond: 2_048,
            upBytesPerSecond: 1_024
        )
        let memoryTelemetry = MenuBarTelemetryPoint(
            date: earlier.addingTimeInterval(7),
            cpuTotal: nil,
            cpuUser: nil,
            cpuSystem: nil,
            gpu: nil,
            memory: 67,
            memoryPressure: 21,
            compressedMemoryBytes: 2_048,
            swapUsedBytes: 0,
            chipTemperature: nil,
            fanRPM: nil,
            downBytesPerSecond: nil,
            upBytesPerSecond: nil
        )
        let disk = NativeDiskIOPoint(
            date: earlier,
            readBytesPerSecond: 4_096,
            writeBytesPerSecond: 2_048,
            readOperationsPerSecond: 8,
            writeOperationsPerSecond: 4
        )
        let oldPower = MenuBarPowerHistoryPoint(
            date: earlier,
            chargePercent: 60,
            batteryPowerWatts: -8,
            isCharging: false,
            powerSource: .batteryPower
        )
        let currentPower = MenuBarPowerHistoryPoint(
            date: now,
            chargePercent: 61,
            batteryPowerWatts: 30,
            isCharging: true,
            powerSource: .acPower
        )

        await store.appendTelemetry(telemetry, now: now)
        await store.appendMemoryTelemetry(memoryTelemetry, now: now)
        await store.appendDiskIO(disk, now: now)
        await store.appendPower(oldPower, now: now)
        await store.appendPower(currentPower, now: now)
        try await store.flush(now: now)

        let restored = await MetricHistoryStore(url: url).load(now: now)
        XCTAssertEqual(restored.telemetry, [telemetry])
        XCTAssertEqual(
            restored.telemetry.first?.temperature(.performanceCores),
            57
        )
        XCTAssertEqual(restored.memoryTelemetry, [memoryTelemetry])
        XCTAssertEqual(restored.diskIO, [disk])
        XCTAssertEqual(restored.power, [oldPower, currentPower])
        XCTAssertEqual(
            restored.power[1].date.timeIntervalSince(restored.power[0].date),
            3_600,
            accuracy: 0.001,
            "The time while the app was not sampling must remain a real gap"
        )
    }

    func testUnifiedMetricHistoryMigratesVersionOneMemoryTelemetry() throws {
        let legacyMemoryPoint = MenuBarTelemetryPoint(
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            cpuTotal: nil,
            cpuUser: nil,
            cpuSystem: nil,
            gpu: nil,
            memory: 55,
            chipTemperature: nil,
            fanRPM: nil,
            downBytesPerSecond: nil,
            upBytesPerSecond: nil
        )
        var legacyDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    MetricHistorySnapshot(telemetry: [legacyMemoryPoint])
                )
            ) as? [String: Any]
        )
        legacyDocument.removeValue(forKey: "memoryTelemetry")

        let snapshot = try JSONDecoder().decode(
            MetricHistorySnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacyDocument)
        )

        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.memoryTelemetry, [legacyMemoryPoint])
    }

    func testUnifiedMetricHistoryMigratesLegacyPowerAndSurvivesCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricHistoryStoreTests-\(UUID().uuidString)")
        let unifiedURL = directory.appendingPathComponent("metric.json")
        let legacyURL = directory.appendingPathComponent("power.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 400_000)
        let legacyPoint = MenuBarPowerHistoryPoint(
            date: now,
            chargePercent: 75,
            batteryPowerWatts: -5,
            isCharging: false,
            powerSource: .batteryPower
        )
        try MenuBarPowerHistoryStore.save([legacyPoint], to: legacyURL)

        let migrated = await MetricHistoryStore(
            url: unifiedURL,
            legacyPowerURL: legacyURL
        ).load(now: now)
        XCTAssertEqual(migrated.power, [legacyPoint])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unifiedURL.path))

        try Data("{not-json".utf8).write(to: unifiedURL, options: .atomic)
        let recovered = await MetricHistoryStore(url: unifiedURL).load(now: now)
        XCTAssertEqual(recovered, .empty)
    }

    func testBatteryAndDiskHistorySurviveWallClockRollbackInMemoryAndPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricHistoryStoreTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let initialDate = Date(timeIntervalSinceReferenceDate: 600_000)
        let rollbackDate = initialDate.addingTimeInterval(-10)
        let power = [
            MenuBarPowerHistoryPoint(
                date: initialDate,
                chargePercent: 70,
                batteryPowerWatts: -5,
                isCharging: false,
                powerSource: .batteryPower
            ),
            MenuBarPowerHistoryPoint(
                date: rollbackDate,
                chargePercent: 69,
                batteryPowerWatts: -5,
                isCharging: false,
                powerSource: .batteryPower
            ),
            MenuBarPowerHistoryPoint(
                date: rollbackDate.addingTimeInterval(1),
                chargePercent: 68,
                batteryPowerWatts: -5,
                isCharging: false,
                powerSource: .batteryPower
            ),
        ]
        let disk = [
            NativeDiskIOPoint(
                date: initialDate,
                readBytesPerSecond: 100,
                writeBytesPerSecond: 50,
                readOperationsPerSecond: 2,
                writeOperationsPerSecond: 1
            ),
            NativeDiskIOPoint(
                date: rollbackDate,
                readBytesPerSecond: 200,
                writeBytesPerSecond: 100,
                readOperationsPerSecond: 4,
                writeOperationsPerSecond: 2
            ),
            NativeDiskIOPoint(
                date: rollbackDate.addingTimeInterval(1),
                readBytesPerSecond: 300,
                writeBytesPerSecond: 150,
                readOperationsPerSecond: 6,
                writeOperationsPerSecond: 3
            ),
        ]

        var inMemoryPower: [MenuBarPowerHistoryPoint] = []
        var inMemoryDisk: [NativeDiskIOPoint] = []
        let store = MetricHistoryStore(url: url)
        for index in power.indices {
            MenuBarHistoryRetention.append(power[index], to: &inMemoryPower, date: \.date)
            MenuBarHistoryRetention.append(disk[index], to: &inMemoryDisk, date: \.date)
            await store.appendPower(power[index], now: power[index].date)
            await store.appendDiskIO(disk[index], now: disk[index].date)
        }

        let displayDate = rollbackDate.addingTimeInterval(1)
        XCTAssertEqual(
            MenuBarHistoryRetention.selected(
                inMemoryPower,
                duration: 60,
                date: \.date,
                referenceDate: displayDate
            ).last,
            power[2]
        )
        XCTAssertEqual(
            MenuBarHistoryRetention.selected(
                inMemoryDisk,
                duration: 60,
                date: \.date,
                referenceDate: displayDate
            ).last,
            disk[2]
        )

        try await store.flush(now: displayDate)
        let restored = await MetricHistoryStore(url: url).load(now: displayDate)
        XCTAssertEqual(inMemoryPower, restored.power)
        XCTAssertEqual(inMemoryDisk, restored.diskIO)
    }

    func testUnifiedMetricHistorySerializesConcurrentOutOfOrderSamplesAndCapsFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricHistoryStoreTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 500_000)
        let store = MetricHistoryStore(url: url)
        await withTaskGroup(of: Void.self) { group in
            for index in (0..<100).reversed() {
                group.addTask {
                    await store.appendPower(
                        MenuBarPowerHistoryPoint(
                            date: now.addingTimeInterval(Double(index - 99)),
                            chargePercent: Double(index % 100),
                            batteryPowerWatts: -4,
                            isCharging: false,
                            powerSource: .batteryPower
                        ),
                        now: now
                    )
                }
            }
        }
        try await store.flush(now: now)

        let restored = await MetricHistoryStore(url: url).load(now: now)
        XCTAssertEqual(restored.power.count, 100)
        XCTAssertEqual(restored.power.map(\.date), restored.power.map(\.date).sorted())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        XCTAssertLessThanOrEqual(size, MetricHistoryStore.maximumFileSize)

        let tinyStore = MetricHistoryStore(
            url: directory.appendingPathComponent("tiny.json"),
            maximumFileSize: 1
        )
        await tinyStore.appendPower(restored.power[0], now: now)
        do {
            try await tinyStore.flush(now: now)
            XCTFail("Expected the hard file cap to reject the write")
        } catch {
            XCTAssertEqual(error as? MetricHistoryStoreError, .fileTooLarge)
        }
    }

    func testUnifiedMetricHistoryKeepsSamplesAcrossResolutionBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricHistoryStoreTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Choose an epoch where the 5-minute and 1-minute bucket indices
        // collide at the 24-hour resolution boundary. The resolution itself
        // must remain part of the bucket identity or one real sample is lost.
        let now = Date(timeIntervalSinceReferenceDate: 86_410)
        let older = MenuBarPowerHistoryPoint(
            date: Date(timeIntervalSinceReferenceDate: 9),
            chargePercent: 50,
            batteryPowerWatts: -4,
            isCharging: false,
            powerSource: .batteryPower
        )
        let newer = MenuBarPowerHistoryPoint(
            date: Date(timeIntervalSinceReferenceDate: 11),
            chargePercent: 51,
            batteryPowerWatts: -4,
            isCharging: false,
            powerSource: .batteryPower
        )
        let store = MetricHistoryStore(url: url)
        await store.appendPower(older, now: now)
        await store.appendPower(newer, now: now)
        try await store.flush(now: now)

        let restored = await MetricHistoryStore(url: url).load(now: now)
        XCTAssertEqual(restored.power, [older, newer])
    }

    func testPowerHistoryRoundTripKeepsChargingAndPowerSourceFacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarPowerHistoryStoreTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let points = [
            MenuBarPowerHistoryPoint(
                date: now.addingTimeInterval(-60),
                chargePercent: 61,
                batteryPowerWatts: -7.5,
                isCharging: false,
                powerSource: .batteryPower
            ),
            MenuBarPowerHistoryPoint(
                date: now,
                chargePercent: 62,
                batteryPowerWatts: 28,
                isCharging: true,
                powerSource: .acPower
            ),
        ]

        try MenuBarPowerHistoryStore.save(points, to: url)

        XCTAssertEqual(MenuBarPowerHistoryStore.load(from: url, now: now), points)
    }

    func testPersistenceKeepsEveryRecentPoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarPowerHistoryStoreTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let recentPointCount = Int(MenuBarHistoryRetention.highResolutionDuration / 2)
        let oldestPointIndex = recentPointCount - 1
        let points: [MenuBarPowerHistoryPoint] = (0..<recentPointCount).map { index in
            let age = Double(index - oldestPointIndex) * 2
            return MenuBarPowerHistoryPoint(
                date: now.addingTimeInterval(age),
                chargePercent: Double(80 + index % 5),
                batteryPowerWatts: -5,
                isCharging: false,
                powerSource: .batteryPower
            )
        }

        XCTAssertEqual(MenuBarPowerHistoryStore.persistablePoints(points), points)

        try MenuBarPowerHistoryStore.save(points, to: url)
        XCTAssertEqual(MenuBarPowerHistoryStore.load(from: url, now: now), points)
    }

    func testLegacyPersistenceTimeBucketsOlderHistoryButKeepsRecentSamples() {
        let end = Date(timeIntervalSinceReferenceDate: 3_000_000)
        let older = (0..<720).map { index in
            MenuBarPowerHistoryPoint(
                date: end.addingTimeInterval(
                    -MenuBarHistoryRetention.duration
                    + Double(index) * (
                        MenuBarHistoryRetention.duration
                            - MenuBarHistoryRetention.highResolutionDuration
                            - 1
                    ) / 719
                ),
                chargePercent: Double(index % 100),
                batteryPowerWatts: -5,
                isCharging: false,
                powerSource: .batteryPower
            )
        }
        let recentPointCount = Int(MenuBarHistoryRetention.highResolutionDuration / 6)
        let oldestRecentIndex = recentPointCount - 1
        let recent: [MenuBarPowerHistoryPoint] = (0..<recentPointCount).map { index in
            let age = Double(index - oldestRecentIndex) * 6
            return MenuBarPowerHistoryPoint(
                date: end.addingTimeInterval(age),
                chargePercent: 80,
                batteryPowerWatts: -5,
                isCharging: false,
                powerSource: .batteryPower
            )
        }

        let persisted = MenuBarPowerHistoryStore.persistablePoints(older + recent)

        XCTAssertEqual(Array(persisted.suffix(recent.count)), recent)
        XCTAssertLessThanOrEqual(persisted.count - recent.count, 360)
        XCTAssertEqual(persisted.last, recent.last)
    }
}
