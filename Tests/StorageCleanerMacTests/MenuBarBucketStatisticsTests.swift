import XCTest
import SwiftUI
@testable import StorageCleanerMac

final class MenuBarBucketStatisticsTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 3_000_000)

    func testMiddleSpikeLowLastAndCPUComponentsSurviveCompaction() throws {
        let merged = compact([point(0, 10), point(10, 90), point(40, 10)])
        let cpu = try XCTUnwrap(merged.bucketStatistics?.metrics["cpuTotal"])
        XCTAssertEqual(cpu.mean, 30, accuracy: 0.000001)
        XCTAssertEqual(cpu.peak, 90)
        XCTAssertEqual(cpu.last, 10)
        XCTAssertEqual(cpu.coveredDuration, 40)
        XCTAssertEqual(cpu.start, start)
        XCTAssertEqual(cpu.end, start.addingTimeInterval(40))
        XCTAssertEqual(cpu.peakDate, start.addingTimeInterval(10))
        XCTAssertEqual(merged.cpuTotal, 10, "the old scalar is still the real last sample")
        XCTAssertEqual(merged.cpuPeakSample.cpuUser, 67.5)
        XCTAssertEqual(merged.cpuPeakSample.cpuSystem, 22.5)
        for key in ["gpu", "download", "upload"] {
            let record = try XCTUnwrap(merged.bucketStatistics?.metrics[key])
            XCTAssertEqual(record.mean, 30, accuracy: 0.000001)
            XCTAssertEqual(record.peak, 90)
            XCTAssertEqual(record.last, 10)
        }
    }

    func testChangingCadenceWeightsTimeInsteadOfSampleCount() throws {
        let irregular = compact([point(0, 0), point(10, 0), point(15, 100), point(25, 0)])
        let regular = compact([point(0, 0), point(5, 0), point(10, 0), point(15, 100), point(20, 0), point(25, 0)])
        for point in [irregular, regular] {
            let cpu = try XCTUnwrap(point.bucketStatistics?.metrics["cpuTotal"])
            XCTAssertEqual(cpu.mean, 20, accuracy: 0.000001)
            XCTAssertEqual(cpu.coveredDuration, 25)
            XCTAssertEqual(cpu.peak, 100)
        }
    }

    func testMissingAndLongOutagesHaveNoSyntheticZeroCoverage() throws {
        let merged = compact([point(0, 10), point(10, 90), point(20, nil), point(40, 10), point(400, 10)])
        let record = try XCTUnwrap(merged.bucketStatistics?.metrics["cpuTotal"])
        XCTAssertEqual(record.coverage, [DateInterval(start: start, end: start.addingTimeInterval(10))])
        XCTAssertEqual(record.mean, 90)
        XCTAssertEqual(record.peak, 90)
        XCTAssertEqual(record.last, 10)
        XCTAssertEqual(MenuBarHistoryStatistic.coverage(from: start, to: start.addingTimeInterval(20),
            gaps: [DateInterval(start: start.addingTimeInterval(5), end: start.addingTimeInterval(15))]), [])
    }

    func testRepeatedHardwarePublicationDoesNotDoubleWeightOrRetimestamp() throws {
        var old = point(0, 10)
        old = .init(date: old.date, cpuTotal: nil, cpuUser: nil, cpuSystem: nil, gpu: 30, memory: nil,
                    chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil,
                    gpuSampledAt: start)
        let cached = MenuBarTelemetryPoint(date: start.addingTimeInterval(30), cpuTotal: nil, cpuUser: nil,
            cpuSystem: nil, gpu: 30, memory: nil, chipTemperature: nil, fanRPM: nil,
            downBytesPerSecond: nil, upBytesPerSecond: nil, gpuSampledAt: start)
        let merged = cached.standingForBucket(replacing: old)
        let gpu = try XCTUnwrap(merged.bucketStatistics?.metrics["gpu"])
        XCTAssertEqual(gpu.sampleCount, 1)
        XCTAssertEqual(gpu.coveredDuration, 0)
        XCTAssertEqual(gpu.lastDate, start)
        XCTAssertEqual(merged.standingForBucket(replacing: merged), merged)
    }

    func testDiskMeasuredIntervalsAndSignedBatteryPowerKeepMeansAndPeaks() throws {
        let disk = [diskPoint(10, 90, interval: 10), diskPoint(40, 10, interval: 30)]
        let combined: NativeDiskIOPoint = MenuBarHistoryRetention.bucketRepresentative(disk[1], replacing: disk[0])
        let read = try XCTUnwrap(combined.bucketStatistics?.metrics["diskRead"])
        XCTAssertEqual(read.mean, 30, accuracy: 0.000001)
        XCTAssertEqual(read.peak, 90)
        XCTAssertEqual(read.coveredDuration, 40)
        let power = [powerPoint(0, -10), powerPoint(10, -90), powerPoint(40, -10)]
        let first: MenuBarPowerHistoryPoint = MenuBarHistoryRetention.bucketRepresentative(power[1], replacing: power[0])
        let last: MenuBarPowerHistoryPoint = MenuBarHistoryRetention.bucketRepresentative(power[2], replacing: first)
        let watts = try XCTUnwrap(last.bucketStatistics?.metrics["batteryPower"])
        XCTAssertEqual(watts.mean, -30, accuracy: 0.000001)
        XCTAssertEqual(watts.minimum, -90, "signed extrema retain the discharging spike")
        XCTAssertEqual(watts.peak, -10)
        XCTAssertEqual(watts.last, -10)
    }

    func testLiveMinuteAndPersistedLongRangeCompactionAreAssociative() throws {
        let raw = [point(0, 10), point(10, 90), point(40, 10)]
        let later = point(3 * 86_400, 10)
        var history = MenuBarTelemetryHistory()
        for point in raw + [later] { history.append(point) }
        let minute = try XCTUnwrap(history.points.first)
        let once = MetricHistoryStore.checkpointSnapshot(.init(telemetry: raw + [later]), longRangeBucket: 300)
        let twice = MetricHistoryStore.checkpointSnapshot(once, longRangeBucket: 1_800)
        for compressed in [minute, try XCTUnwrap(once.telemetry.first), try XCTUnwrap(twice.telemetry.first)] {
            let cpu = try XCTUnwrap(compressed.bucketStatistics?.metrics["cpuTotal"])
            XCTAssertEqual(cpu.mean, 30, accuracy: 0.000001)
            XCTAssertEqual(cpu.peak, 90)
            XCTAssertEqual(cpu.coveredDuration, 40)
        }
    }

    func testChartsUseStoredMeansAndRealPeaksRatherThanTheLowLastValue() throws {
        let merged = compact([point(0, 10), point(10, 90), point(40, 10)])
        let network = GeekNetworkHistorySnapshot(points: [merged])
        XCTAssertEqual(network.downloadStatistics?.average, 30)
        XCTAssertEqual(network.downloadStatistics?.maximum, 90)
        XCTAssertEqual(network.downloadStatistics?.current, 10)
        XCTAssertTrue(network.hasRenderableData)
        let cpu = GeekPreparedLineSummary(points: [merged], channels: [.cpuTotal])
        XCTAssertEqual(cpu.channels, [.cpuTotal])
        XCTAssertEqual(cpu.statistics[.cpuTotal]?.maximum, 90)
        XCTAssertEqual(cpu.statistics[.cpuTotal]?.average, 30)
        let plot = CGRect(x: 0, y: 0, width: 360, height: 100)
        for duration in [TimeInterval(60), 3_600] {
            let frame = GeekCPUHistoryFrame.prepare(points: [merged], plotRect: plot, duration: duration,
                referenceDate: start.addingTimeInterval(duration), samplingInterval: 1, displayScale: 2)
            XCTAssertEqual(frame.marks.first?.peakTotal, 90)
            XCTAssertEqual(frame.marks.first?.peak.cpuUser, 67.5)
            XCTAssertEqual(frame.marks.first?.mean.cpuTotal, 30)
        }
        let disk: NativeDiskIOPoint = MenuBarHistoryRetention.bucketRepresentative(diskPoint(40, 10, interval: 30), replacing: diskPoint(10, 90, interval: 10))
        let diskSummary = GeekPreparedDiskSummary(points: [disk], duration: 3_600, referenceDate: start.addingTimeInterval(3_600))
        XCTAssertEqual(diskSummary.readPeakBytesPerSecond, 90)
        XCTAssertEqual(diskSummary.read?.average, 30)
    }

    func testCompressedCoverageProjectsSeparateRunsWithoutFillingASleepGap() throws {
        let a = MenuBarHistoryStatistic(value: 90, date: start.addingTimeInterval(10),
            coverage: [DateInterval(start: start, end: start.addingTimeInterval(10))])
        let b = MenuBarHistoryStatistic(value: 10, date: start.addingTimeInterval(50),
            coverage: [DateInterval(start: start.addingTimeInterval(40), end: start.addingTimeInterval(50))])
        let record = a.merging(b)
        let encoded = try JSONEncoder().encode(MenuBarHistoryStatistics(metrics: ["download": record]))
        let restored = try JSONDecoder().decode(MenuBarHistoryStatistics.self, from: encoded).metrics["download"]
        let bins = (0..<6).map { index in GeekChartBucketSnapshot(indices: [], x: CGFloat(index),
            start: start.addingTimeInterval(Double(index) * 10), end: start.addingTimeInterval(Double(index + 1) * 10)) }
        let projected = GeekCompressedHistoryProjection.buckets(bins, dates: [start.addingTimeInterval(50)], records: [restored])
        XCTAssertEqual(projected.map { $0.indices.isEmpty }, [false, true, true, true, false, true])
        XCTAssertFalse(projected.contains(where: \.isEstimated))
        XCTAssertNil(projected[2].mean { _ in 0 })
    }

    func testRestartAndLegacySnapshotMigrationPreserveValidHistory() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let oldURL = root.appendingPathComponent("old.json")
        let url = root.appendingPathComponent("new.json")
        let now = start.addingTimeInterval(3 * 86_400)
        let original = MetricHistorySnapshot(telemetry: [point(0, 10), point(10, 90), point(40, 10), point(3 * 86_400, 10)],
            diskIO: [diskPoint(10, 90, interval: 10), diskPoint(40, 10, interval: 30), diskPoint(3 * 86_400, 0, interval: 10)])
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: oldURL)
        let store = MetricHistoryStore(url: url, legacyMetricURL: oldURL)
        let migrated = await store.load(now: now)
        XCTAssertFalse(migrated.telemetry.isEmpty)
        try await store.flush(now: now)
        let restarted = await MetricHistoryStore(url: url).load(now: now)
        XCTAssertEqual(try XCTUnwrap(restarted.telemetry.first?.bucketStatistics?.metrics["cpuTotal"]).peak, 90)
        XCTAssertEqual(try XCTUnwrap(restarted.telemetry.first?.bucketStatistics?.metrics["cpuTotal"]).mean, 30, accuracy: 0.000001)
        XCTAssertEqual(try Data(contentsOf: oldURL), bytes, "valid legacy source is preserved")
        XCTAssertEqual(restarted.diskIO.first?.bucketStatistics?.metrics["diskRead"]?.peak, 90)
    }

    func testSizeCeilingStillRejectsOversizedCheckpointAndNeverDeletesInput() async throws {
        XCTAssertEqual(MetricHistoryStore.maximumFileSize, 16 * 1_024 * 1_024)
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("tiny.json")
        let store = MetricHistoryStore(url: url, maximumFileSize: 1)
        await store.appendTelemetry(compact([point(0, 10), point(10, 90), point(40, 10)]), now: start.addingTimeInterval(40))
        do { try await store.flush(now: start.addingTimeInterval(40)); XCTFail("size ceiling must reject") }
        catch { XCTAssertEqual(error as? MetricHistoryStoreError, .fileTooLarge) }
        let retained = await store.load(now: start.addingTimeInterval(40))
        XCTAssertEqual(retained.telemetry.first?.bucketStatistics?.metrics["cpuTotal"]?.peak, 90)
    }

    func testHighlyFragmentedCoverageSplitsBucketsAndRemainsDecodable() throws {
        let observations = (0..<600).map { index -> MenuBarTelemetryPoint in
            let end = start.addingTimeInterval(Double(index) * 2 + 1)
            var sample = point(Double(index) * 2 + 1, index == 277 ? 99 : 10)
            sample.bucketStatistics = MenuBarHistoryStatistics(metrics: ["cpuTotal":
                .init(value: index == 277 ? 99 : 10, date: end,
                      coverage: [DateInterval(start: end.addingTimeInterval(-0.5), end: end)])])
            return sample
        }
        let smaller = MetricHistoryStore.checkpointSnapshot(.init(telemetry: observations + [point(3 * 86_400, 0)]), longRangeBucket: 300)
        let persisted = MetricHistoryStore.checkpointSnapshot(smaller, longRangeBucket: 1_800)
        let restored = try JSONDecoder().decode(MetricHistorySnapshot.self, from: JSONEncoder().encode(persisted))
        let records = restored.telemetry.dropLast().compactMap { $0.bucketStatistics?.metrics["cpuTotal"] }
        XCTAssertEqual(records.map(\.sampleCount).reduce(0, +), 600)
        XCTAssertEqual(records.map(\.coveredDuration).reduce(0, +), 300)
        XCTAssertEqual(records.map(\.peak).max(), 99)
        XCTAssertTrue(records.allSatisfy { $0.coverage.count <= 256 })
    }

    func testSharedContextEncodingKeepsAllStatisticsAndReadsVerboseObjects() throws {
        let record = try XCTUnwrap(compact([point(0, 10), point(10, 90), point(40, 10)]).bucketStatistics?.metrics["cpuTotal"])
        let metrics = Dictionary(uniqueKeysWithValues: MenuBarTelemetryChannel.allCases.map { ($0.rawValue, record) })
        let compact = try JSONEncoder().encode(MenuBarHistoryStatistics(metrics: metrics))
        let verbose = try JSONEncoder().encode(VerboseStatistics(metrics: metrics))
        XCTAssertLessThan(compact.count, verbose.count / 2)
        for data in [compact, verbose] {
            XCTAssertEqual(try JSONDecoder().decode(MenuBarHistoryStatistics.self, from: data).metrics, metrics)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: compact) as? [String: Any])
        object["contexts"] = []
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(MenuBarHistoryStatistics.self, from: corrupt))
    }

    func testDense28DayAllChannelCheckpointStillFitsTheRealSizeCeiling() async throws {
        let now = start.addingTimeInterval(28 * 86_400)
        func dense(_ date: Date) -> MenuBarTelemetryPoint {
            MenuBarTelemetryPoint(date: date, cpuTotal: 60, cpuUser: 40, cpuSystem: 20,
                gpu: 60, memory: 60, memoryPressure: 60, memoryPressureLevelCode: 1,
                memoryAppOrOtherBytes: 8_000_000_000, memoryWiredBytes: 4_000_000_000,
                memoryPhysicalBytes: 32_000_000_000, compressedMemoryBytes: 3_000_000_000,
                swapUsedBytes: 2_000_000_000, chipTemperature: 60, gpuTemperature: 60,
                temperatureReadings: SystemTemperatureZone.allCases.map { .init(zone: $0, celsius: 60) },
                fanRPM: 1_500, fanTargetRPM: 1_800, downBytesPerSecond: 60_000_000, upBytesPerSecond: 30_000_000,
                sensorSampledAt: date, gpuSampledAt: date)
        }
        var points: [MenuBarTelemetryPoint] = []
        let raw = try XCTUnwrap(compact([point(0, 10), point(10, 90), point(60, 20)]).bucketStatistics?.metrics["cpuTotal"])
        // Full minute coverage over 28 days plus the dense recent second ring.
        for minute in 1...(28 * 24 * 60 - 60) {
            let date = start.addingTimeInterval(Double(minute * 60))
            var sample = dense(date)
            // Use the same measured source context, with nontrivial means/peaks,
            // for every numerical channel; no channel may be dropped for size.
            let a = MenuBarHistoryStatistic(value: raw.peak, date: date.addingTimeInterval(-50),
                coverage: [.init(start: date.addingTimeInterval(-60), end: date.addingTimeInterval(-50))])
            let b = MenuBarHistoryStatistic(value: raw.last, date: date,
                coverage: [.init(start: date.addingTimeInterval(-50), end: date)])
            let record = a.merging(b)
            sample.bucketStatistics = .init(metrics: Dictionary(uniqueKeysWithValues:
                MenuBarTelemetryChannel.allCases.map { ($0.rawValue, record) }))
            points.append(sample)
        }
        let recentStart = now.addingTimeInterval(-3_600)
        points += (1...3_600).map { dense(recentStart.addingTimeInterval(Double($0))) }
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("dense.json")
        let checkpoint = MetricHistoryStore.checkpointSnapshot(.init(telemetry: points), longRangeBucket: 1_800)
        let encoded = try JSONEncoder().encode(checkpoint)
        print("R3 28-day all-channel checkpoint: \(encoded.count) bytes; ceiling \(MetricHistoryStore.maximumFileSize) bytes")
        XCTAssertLessThanOrEqual(encoded.count, MetricHistoryStore.maximumFileSize)
        try encoded.write(to: url)
        let store = MetricHistoryStore(url: url)
        let restored = await store.load(now: now)
        try await store.flush(now: now)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, MetricHistoryStore.maximumFileSize)
        let first = try XCTUnwrap(restored.telemetry.first)
        XCTAssertLessThanOrEqual(first.date.timeIntervalSince(start), 1_800)
        XCTAssertEqual(first.bucketStatistics?.metrics.count, MenuBarTelemetryChannel.allCases.count)
        XCTAssertEqual(first.bucketStatistics?.metrics["cpuTotal"]?.peak, 90)
        XCTAssertEqual(first.bucketStatistics?.metrics["cpuTotal"]?.mean, 31.666666666666668)
    }

    func testSameTimestampReplayKeepsTheAccumulatedBucketStatistics() throws {
        let merged = compact([point(0, 10), point(10, 90), point(40, 10)])
        let replay = point(40, 10)
        XCTAssertNil(replay.bucketStatistics)
        XCTAssertEqual(replay.standingForBucket(replacing: merged).bucketStatistics, merged.bucketStatistics)
        let telemetry: MenuBarTelemetryPoint = MenuBarHistoryRetention.bucketRepresentative(replay, replacing: merged)
        XCTAssertEqual(telemetry.bucketStatistics?.metrics["cpuTotal"]?.peak, 90)
        let disk: NativeDiskIOPoint = MenuBarHistoryRetention.bucketRepresentative(
            diskPoint(40, 10, interval: 30), replacing: diskPoint(10, 90, interval: 10))
        let diskReplay: NativeDiskIOPoint = MenuBarHistoryRetention.bucketRepresentative(
            diskPoint(40, 10, interval: 30), replacing: disk)
        XCTAssertEqual(diskReplay.bucketStatistics, disk.bucketStatistics)
        XCTAssertEqual(diskReplay.bucketStatistics?.metrics["diskRead"]?.peak, 90)
        let power: MenuBarPowerHistoryPoint = MenuBarHistoryRetention.bucketRepresentative(
            powerPoint(40, -10), replacing: powerPoint(10, -90))
        let powerReplay: MenuBarPowerHistoryPoint = MenuBarHistoryRetention.bucketRepresentative(
            powerPoint(40, -10), replacing: power)
        XCTAssertEqual(powerReplay.bucketStatistics, power.bucketStatistics)
        XCTAssertEqual(powerReplay.bucketStatistics?.metrics["batteryPower"]?.minimum, -90)
    }

    func testLargeMagnitudeMeansStayWithinTheirRangeAndDecode() throws {
        // 60 GB/s with a relative drift of 1e-12 (0.06 B/s absolute).
        let peak = 60_000_000_000.0
        let drifted = peak * (1 + 1e-12)
        XCTAssertGreaterThan(drifted - peak, 0.000001)
        let verbose = """
        {"metrics":{"download":{"mean":\(drifted),"peak":\(peak),"minimum":1000,"last":\(peak),\
        "peakDate":10,"lastDate":20,"sampleCount":2,"coverage":[{"start":0,"duration":20}]}}}
        """
        let decoded = try JSONDecoder().decode(MenuBarHistoryStatistics.self, from: Data(verbose.utf8))
        let record = try XCTUnwrap(decoded.metrics["download"])
        // A newer sample exactly at the peak: weighting the drifted mean with
        // it lands above the true peak unless the merge clamps it.
        let next = MenuBarHistoryStatistic(value: peak, date: Date(timeIntervalSinceReferenceDate: 30),
            coverage: [DateInterval(start: Date(timeIntervalSinceReferenceDate: 20), duration: 10)])
        let merged = record.merging(next)
        XCTAssertLessThanOrEqual(merged.mean, merged.peak)
        XCTAssertGreaterThanOrEqual(merged.mean, merged.minimum)
        XCTAssertTrue(merged.isValid)
        let roundTrip = try JSONDecoder().decode(MenuBarHistoryStatistics.self,
            from: JSONEncoder().encode(MenuBarHistoryStatistics(metrics: ["download": merged])))
        XCTAssertEqual(roundTrip.metrics["download"]?.peak, merged.peak)
        // A real violation is still rejected.
        let corrupt = verbose.replacingOccurrences(of: "\"mean\":\(drifted)", with: "\"mean\":\(peak * 1.001)")
        XCTAssertThrowsError(try JSONDecoder().decode(MenuBarHistoryStatistics.self, from: Data(corrupt.utf8)))
    }

    /// P1-4: the upgrade migration runs inside `MetricHistoryStore.load` (its
    /// actor), so the main-actor restore receives points that need no work.
    func testLegacyTwentyThousandPointMigrationHappensInTheStoreNotOnRestore() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let legacyURL = root.appendingPathComponent("legacy.json")
        let url = root.appendingPathComponent("history.json")
        let now = start.addingTimeInterval(20_000 * 60 + 7_200)
        let legacy = (0..<20_000).map { index in point(Double(index) * 60, Double(index % 100)) }
        try JSONEncoder().encode(MetricHistorySnapshot(telemetry: legacy)).write(to: legacyURL)
        let loaded = await MetricHistoryStore(url: url, legacyMetricURL: legacyURL).load(now: now)
        XCTAssertEqual(loaded.telemetry.count, 20_000)
        let rawWindow = try XCTUnwrap(loaded.telemetry.last?.date)
            .addingTimeInterval(-MenuBarHistoryRetention.highResolutionDuration)
        let older = loaded.telemetry.filter { $0.date < rawWindow }
        XCTAssertEqual(older.count, 20_000 - 61)
        XCTAssertTrue(older.allSatisfy { $0.bucketStatistics != nil }, "statistics were prepared on the store's actor")
        XCTAssertTrue(loaded.telemetry.filter { $0.date >= rawWindow }.allSatisfy { $0.bucketStatistics == nil })
        let restored = await MainActor.run { () -> [MenuBarTelemetryPoint] in
            var history = MenuBarTelemetryHistory()
            history.restore(loaded.telemetry)
            return history.points
        }
        XCTAssertEqual(restored, loaded.telemetry, "restore had nothing left to compute")
        XCTAssertEqual(restored[older.count - 1].bucketStatistics?.metrics["cpuTotal"]?.last, Double((20_000 - 62) % 100))
    }

    /// P1-5: realistic 28-day shape of all four persisted arrays, measured
    /// through the production checkpoint tiers (5 min, then 30 min).
    func testRealistic28DayFourArrayCheckpointFitsTheCeiling() throws {
        let end = start.addingTimeInterval(28 * 86_400)
        let recentStart = end.addingTimeInterval(-3_600)
        func telemetryPoint(_ date: Date) -> MenuBarTelemetryPoint {
            MenuBarTelemetryPoint(date: date, cpuTotal: 37.5, cpuUser: 25.25, cpuSystem: 12.25,
                gpu: 18.5, memory: nil, chipTemperature: 61.4, gpuTemperature: 55.2,
                temperatureReadings: [.init(zone: .chip, celsius: 61.4), .init(zone: .gpu, celsius: 55.2),
                    .init(zone: .soc, celsius: 58.1), .init(zone: .performanceCores, celsius: 63.7),
                    .init(zone: .efficiencyCores, celsius: 49.3), .init(zone: .storage, celsius: 41.2),
                    .init(zone: .battery, celsius: 33.6), .init(zone: .ambient, celsius: 29.8)],
                fanRPM: 1_712, fanTargetRPM: 1_700, downBytesPerSecond: 1_234_567, upBytesPerSecond: 234_567,
                sensorSampledAt: date.addingTimeInterval(-3), gpuSampledAt: date.addingTimeInterval(-1))
        }
        func memoryPoint(_ date: Date) -> MenuBarTelemetryPoint {
            MenuBarTelemetryPoint(date: date, cpuTotal: nil, cpuUser: nil, cpuSystem: nil, gpu: nil,
                memory: 71.3, memoryPressure: 23.5, memoryPressureLevelCode: 1,
                memoryAppOrOtherBytes: 17_179_869_184, memoryWiredBytes: 4_294_967_296,
                memoryPhysicalBytes: 34_359_738_368, compressedMemoryBytes: 2_147_483_648,
                swapUsedBytes: 1_073_741_824, chipTemperature: nil, fanRPM: nil,
                downBytesPerSecond: nil, upBytesPerSecond: nil)
        }
        // A completed live minute bucket: two observations, different values,
        // per-channel source times (point / GPU / sensors) like production.
        func minuteBucket(_ point: MenuBarTelemetryPoint) -> MenuBarTelemetryPoint {
            var bucket = point
            var metrics: [String: MenuBarHistoryStatistic] = [:]
            for channel in MenuBarTelemetryChannel.allCases {
                guard let value = channel.value(in: point) else { continue }
                let source = channel.sampleDate(in: point)
                let first = MenuBarHistoryStatistic(value: value * 1.4, date: source.addingTimeInterval(-30),
                    coverage: [DateInterval(start: source.addingTimeInterval(-60), end: source.addingTimeInterval(-30))],
                    peakCompanions: channel == .cpuTotal ? ["cpuUser": 35.35, "cpuSystem": 17.15] : nil)
                let second = MenuBarHistoryStatistic(value: value, date: source,
                    coverage: [DateInterval(start: source.addingTimeInterval(-30), end: source)])
                metrics[channel.rawValue] = first.merging(second)
            }
            bucket.bucketStatistics = MenuBarHistoryStatistics(metrics: metrics)
            return bucket
        }
        var telemetry: [MenuBarTelemetryPoint] = [], memory: [MenuBarTelemetryPoint] = []
        var disk: [NativeDiskIOPoint] = [], power: [MenuBarPowerHistoryPoint] = []
        var minute = start.addingTimeInterval(60)
        while minute < recentStart {
            telemetry.append(minuteBucket(telemetryPoint(minute)))
            memory.append(minuteBucket(memoryPoint(minute)))
            let firstDisk = NativeDiskIOPoint(date: minute.addingTimeInterval(-30), readBytesPerSecond: 9_876_543,
                writeBytesPerSecond: 1_234_567, readOperationsPerSecond: 321.5, writeOperationsPerSecond: 87.25,
                intervalStart: minute.addingTimeInterval(-60))
            let secondDisk = NativeDiskIOPoint(date: minute, readBytesPerSecond: 2_345_678,
                writeBytesPerSecond: 345_678, readOperationsPerSecond: 123.5, writeOperationsPerSecond: 45.25,
                intervalStart: minute.addingTimeInterval(-30))
            disk.append(MenuBarHistoryRetention.bucketRepresentative(secondDisk, replacing: firstDisk, gaps: []))
            power.append(MenuBarHistoryRetention.bucketRepresentative(
                MenuBarPowerHistoryPoint(date: minute, chargePercent: 76, batteryPowerWatts: -11.5,
                                         isCharging: false, powerSource: .batteryPower),
                replacing: MenuBarPowerHistoryPoint(date: minute.addingTimeInterval(-30), chargePercent: 77,
                    batteryPowerWatts: -14.25, isCharging: false, powerSource: .batteryPower), gaps: []))
            minute.addTimeInterval(60)
        }
        for second in 0..<3_600 {
            let date = recentStart.addingTimeInterval(Double(second) + 1)
            telemetry.append(telemetryPoint(date))
            memory.append(memoryPoint(date))
            disk.append(NativeDiskIOPoint(date: date, readBytesPerSecond: 2_345_678, writeBytesPerSecond: 345_678,
                readOperationsPerSecond: 123.5, writeOperationsPerSecond: 45.25, intervalStart: date.addingTimeInterval(-1)))
            power.append(MenuBarPowerHistoryPoint(date: date, chargePercent: 76, batteryPowerWatts: -11.5,
                                                  isCharging: false, powerSource: .batteryPower))
        }
        let snapshot = MetricHistorySnapshot(telemetry: telemetry, memoryTelemetry: memory, diskIO: disk, power: power)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var report: [String] = []
        var chosenTier: TimeInterval?
        var chosenBytes = 0
        let tiers: [TimeInterval] = [300, 1_800]
        for tier in tiers {
            let checkpoint = MetricHistoryStore.checkpointSnapshot(snapshot, longRangeBucket: tier)
            let bytes: Int = try encoder.encode(checkpoint).count
            let telemetryBytes: Int = try encoder.encode(checkpoint.telemetry).count
            let memoryBytes: Int = try encoder.encode(checkpoint.memoryTelemetry).count
            let diskBytes: Int = try encoder.encode(checkpoint.diskIO).count
            let powerBytes: Int = try encoder.encode(checkpoint.power).count
            let counts = [checkpoint.telemetry.count, checkpoint.memoryTelemetry.count,
                          checkpoint.diskIO.count, checkpoint.power.count]
            var line = "tier \(Int(tier))s: \(bytes) bytes; points \(counts); "
            line += "telemetry=\(telemetryBytes) memory=\(memoryBytes) disk=\(diskBytes) power=\(powerBytes)"
            report.append(line)
            if chosenTier == nil, bytes <= MetricHistoryStore.maximumFileSize {
                chosenTier = tier
                chosenBytes = bytes
            }
        }
        let chosenText = chosenTier.map { "\(Int($0))s" } ?? "none"
        print("R3 realistic 28-day 4-array checkpoint: " + report.joined(separator: " | ")
              + " | ceiling \(MetricHistoryStore.maximumFileSize); chosen tier " + chosenText)
        let tier = try XCTUnwrap(chosenTier, "the production tiers must fit 16 MiB without dropping channels")
        XCTAssertLessThanOrEqual(chosenBytes, MetricHistoryStore.maximumFileSize)
        let checkpoint = MetricHistoryStore.checkpointSnapshot(snapshot, longRangeBucket: tier)
        let restored = try JSONDecoder().decode(MetricHistorySnapshot.self, from: encoder.encode(checkpoint))
        let first = try XCTUnwrap(restored.telemetry.first?.bucketStatistics?.metrics["cpuTotal"])
        XCTAssertEqual(first.peak, 37.5 * 1.4, accuracy: 0.000001)
        XCTAssertEqual(restored.memoryTelemetry.first?.bucketStatistics?.metrics["memory"]?.peak ?? 0, 71.3 * 1.4, accuracy: 0.000001)
        XCTAssertEqual(restored.diskIO.first?.bucketStatistics?.metrics["diskRead"]?.peak, 9_876_543)
        XCTAssertEqual(restored.power.first?.bucketStatistics?.metrics["batteryPower"]?.minimum, -14.25)
    }

    func testPowerProjectionToleratesDuplicateDates() {
        let duplicate = [powerPoint(0, -10), powerPoint(10, -90), powerPoint(10, -80), powerPoint(40, -10)]
        let merged: MenuBarPowerHistoryPoint = MenuBarHistoryRetention.bucketRepresentative(duplicate[3], replacing: duplicate[2])
        let points = [duplicate[0], duplicate[1], duplicate[2], merged]
        let kernel = GeekPowerPreparationKernel(points: points, metric: .batteryPower, duration: 3_600, displayScale: 2)
        let frame = GeekPreparedPowerFrame(kernel: kernel, plot: CGRect(x: 0, y: 0, width: 280, height: 100),
                                           reference: start.addingTimeInterval(60))
        XCTAssertFalse(frame.buckets.isEmpty)
    }

    private func compact(_ points: [MenuBarTelemetryPoint]) -> MenuBarTelemetryPoint {
        points.dropFirst().reduce(points[0]) { $1.standingForBucket(replacing: $0) }
    }
    private func point(_ offset: Double, _ value: Double?) -> MenuBarTelemetryPoint {
        .init(date: start.addingTimeInterval(offset), cpuTotal: value, cpuUser: value.map { $0 * 0.75 },
              cpuSystem: value.map { $0 * 0.25 }, gpu: value, memory: nil, chipTemperature: nil,
              fanRPM: nil, downBytesPerSecond: value.map { Int64($0) }, upBytesPerSecond: value.map { Int64($0) })
    }
    private func diskPoint(_ offset: Double, _ value: Int64, interval: Double) -> NativeDiskIOPoint {
        .init(date: start.addingTimeInterval(offset), readBytesPerSecond: value, writeBytesPerSecond: value,
              readOperationsPerSecond: Double(value), writeOperationsPerSecond: 0,
              intervalStart: start.addingTimeInterval(offset - interval))
    }
    private func powerPoint(_ offset: Double, _ watts: Double) -> MenuBarPowerHistoryPoint {
        .init(date: start.addingTimeInterval(offset), chargePercent: 50, batteryPowerWatts: watts,
              isCharging: false, powerSource: .batteryPower)
    }
}

private struct VerboseStatistics: Encodable {
    let metrics: [String: MenuBarHistoryStatistic]
}
