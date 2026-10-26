import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// The memory-pressure level is the system's level
/// (`kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical,
/// the codes of Dispatch's memory-pressure source). The pressure percent
/// (100 minus the system's free percentage) is a displayed figure only: the
/// kernel does not derive its level from that percent alone. History samples
/// record the level they were taken at and are colored one by one; a sample
/// with only the percent is estimated by the single percent rule.
final class MiniWindowMemoryPressureLevelTests: XCTestCase {
    private let gibibyte: Int64 = 1_024 * 1_024 * 1_024

    // MARK: - The level is the system's level

    func testSystemCodesAreTheDispatchMemoryPressureCodes() {
        XCTAssertEqual(MemoryPressureLevel(systemCode: 1), .normal)
        XCTAssertEqual(MemoryPressureLevel(systemCode: 2), .elevated)
        XCTAssertEqual(MemoryPressureLevel(systemCode: 4), .critical)
        for unknown in [0, 3, 5, 8, -1] { XCTAssertNil(MemoryPressureLevel(systemCode: unknown)) }
        for level in [MemoryPressureLevel.normal, .elevated, .critical] {
            XCTAssertEqual(MemoryPressureLevel(systemCode: level.systemCode), level)
        }
        XCTAssertLessThan(MemoryPressureLevel.normal.severity, MemoryPressureLevel.elevated.severity)
        XCTAssertLessThan(MemoryPressureLevel.elevated.severity, MemoryPressureLevel.critical.severity)
    }

    func testProbeReportsTheSystemLevelWhateverThePercentAndTheOldHeuristicSay() async {
        // The injected level differs from this Mac's real state, so a probe
        // that derived the level from its own readings cannot pass.
        for (code, level) in [(Int32(1), MemoryPressureLevel.normal), (2, .elevated), (4, .critical)] {
            let probe = SystemMemoryProbe(systemPressureLevelCode: { code })
            for includesHeadroom in [false, true] {
                let snapshot = await probe.snapshot(includeProcesses: false, includePressureReading: includesHeadroom)
                XCTAssertEqual(snapshot.measurements.pressure.value, level, "code \(code)")
                XCTAssertEqual(snapshot.measurements.pressure.availability, .available)
                XCTAssertEqual(snapshot.reportablePressureLevel, level)
                XCTAssertEqual(snapshot.cleanupPlan.title == L10n.text("当前状态正常", "Memory looks normal"),
                               level == .normal, "advice follows the same level")
                XCTAssertEqual(MenuBarTelemetryPoint(memorySnapshot: snapshot).memoryPressureLevelCode, Int(code))
            }
        }
    }

    func testAnUnreadableOrUnknownSystemLevelStaysUnavailable() async {
        for code: Int32? in [nil, 3] {
            let probe = SystemMemoryProbe(systemPressureLevelCode: { code })
            let snapshot = await probe.snapshot(includeProcesses: false, includePressureReading: false)
            XCTAssertNil(snapshot.measurements.pressure.value, "\(String(describing: code))")
            XCTAssertNotEqual(snapshot.measurements.pressure.availability, .available)
            XCTAssertTrue(snapshot.measurements.pressure.reason?.contains("kern.memorystatus_vm_pressure_level") == true)
            XCTAssertNil(snapshot.reportablePressureLevel, "no level and no percent: unavailable, not a guess")
            XCTAssertNil(MenuBarTelemetryPoint(memorySnapshot: snapshot).memoryPressureLevelCode)
            XCTAssertNotEqual(snapshot.quality, .complete)
            XCTAssertTrue(snapshot.warnings.contains {
                if case let .metricUnavailable(name, _) = $0 { return name == "Pressure level" }
                return false
            })
        }
    }

    /// Read-only: the default reader is the kernel's pressure level.
    func testDefaultReaderIsTheKernelPressureLevel() async throws {
        let before = try Self.kernelPressureLevel()
        let read = SystemMemoryProbe.readSystemPressureLevelCode()
        let snapshot = await SystemMemoryProbe().snapshot(includeProcesses: false, includePressureReading: false)
        let after = try Self.kernelPressureLevel()
        try XCTSkipIf(before != after, "the system level changed during the test")
        XCTAssertEqual(read, before)
        XCTAssertEqual(snapshot.measurements.pressure.value, MemoryPressureLevel(systemCode: Int(before)))
        XCTAssertNotNil(MemoryPressureLevel(systemCode: Int(before)), "the kernel reported an unknown code \(before)")
    }

    func testAMeasuredLevelIsNotOverriddenByThePercent() {
        // The reviewed readings: 49 % shown as elevated and 56 % as high came
        // from the app's own estimate (available ratio, swap, compression),
        // which D28 removed. The system level decides; without it the percent
        // rule reads both as normal.
        for (headroom, available, compressed, swap) in [(51, 0.10, 0.26, 2.5), (44, 0.04, 0.35, 5.0)] {
            XCTAssertEqual(MemoryPressureLevel.estimated(fromPressurePercent: Double(100 - headroom)), .normal)
            for measured in [MemoryPressureLevel.normal, .elevated, .critical] {
                let snapshot = memorySnapshot(headroom: headroom, available: available, compressed: compressed,
                                              swapGiB: swap, measured: measured)
                XCTAssertEqual(snapshot.pressureEstimatePercent, 100 - headroom)
                XCTAssertEqual(snapshot.reportablePressureLevel, measured,
                               "\(100 - headroom) %: the system said \(measured)")
            }
        }
    }

    // MARK: - Samples without a system level

    func testThePercentEstimateIsTheSinglePercentRule() {
        for (percent, level) in [(0.0, MemoryPressureLevel.normal), (49, .normal), (56, .normal), (84.4, .normal),
                                 (85, .elevated), (94.4, .elevated), (95, .critical), (100, .critical)] {
            XCTAssertEqual(MemoryPressureLevel.estimated(fromPressurePercent: percent), level, "\(percent) %")
            XCTAssertEqual(MemoryPressureLevel.estimated(fromPressurePercent: percent),
                           MemoryPressurePolicy.classify(pressureFreePercentage: Int((100 - percent).rounded())))
        }
        for invalid in [Double.nan, .infinity, -1, 100.5] {
            XCTAssertNil(MemoryPressureLevel.estimated(fromPressurePercent: invalid))
        }
    }

    func testASnapshotWithoutASystemLevelIsEstimatedFromThePercentOnly() {
        // Without a measured level the old code fell back to the multi-factor
        // heuristic and reported these as elevated and critical.
        let elevatedByHeuristic = memorySnapshot(headroom: 51, available: 0.10, compressed: 0.26, swapGiB: 2.5, measured: nil)
        XCTAssertEqual(elevatedByHeuristic.reportablePressureLevel, .normal, "49 %")
        let criticalByHeuristic = memorySnapshot(headroom: 44, available: 0.04, compressed: 0.35, swapGiB: 5, measured: nil)
        XCTAssertEqual(criticalByHeuristic.reportablePressureLevel, .normal, "56 %")
        XCTAssertEqual(memorySnapshot(headroom: 12, available: 0.5, compressed: 0, swapGiB: 0, measured: nil)
            .reportablePressureLevel, .elevated, "88 %")
        XCTAssertEqual(memorySnapshot(headroom: 3, available: 0.5, compressed: 0, swapGiB: 0, measured: nil)
            .reportablePressureLevel, .critical, "97 %")
        XCTAssertNil(memorySnapshot(headroom: nil, available: 0.04, compressed: 0.35, swapGiB: 5, measured: nil)
            .reportablePressureLevel, "no level and no percent")
    }

    // MARK: - History records and draws each sample's level

    func testHistorySamplesRecordTheSystemLevelAndOlderSamplesStillDecode() throws {
        let snapshot = memorySnapshot(headroom: 40, available: 0.5, compressed: 0.1, swapGiB: 0, measured: .elevated)
        let point = MenuBarTelemetryPoint(memorySnapshot: snapshot)
        XCTAssertEqual(point.memoryPressure, 60)
        XCTAssertEqual(point.memoryPressureLevelCode, 2)
        XCTAssertEqual(point.memoryPressureLevel, .elevated, "the recorded level, not the 60 % estimate")
        XCTAssertEqual(point.replacingFanRPM(with: 1_200).memoryPressureLevelCode, 2)
        XCTAssertEqual(point.replacingMemory(with: 70).memoryPressureLevelCode, 2)

        let data = try JSONEncoder().encode(point)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarTelemetryPoint.self, from: data), point)

        // A sample written before the level was recorded has no such key.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["memoryPressureLevelCode"] as? Int, 2)
        object.removeValue(forKey: "memoryPressureLevelCode")
        let legacy = try JSONDecoder().decode(
            MenuBarTelemetryPoint.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.memoryPressureLevelCode)
        XCTAssertEqual(legacy.memoryPressure, 60)
        XCTAssertEqual(legacy.memoryPressureLevel, .normal, "estimated from 60 %")
        // An unknown code is no level; the history still decodes.
        object["memoryPressureLevelCode"] = 3
        let unknown = try JSONDecoder().decode(
            MenuBarTelemetryPoint.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(unknown.memoryPressureLevel, .normal)

        XCTAssertEqual(sample(at: 0, percent: 90, code: nil).memoryPressureLevel, .elevated)
        XCTAssertEqual(sample(at: 0, percent: 97, code: nil).memoryPressureLevel, .critical)
        XCTAssertNil(sample(at: 0, percent: nil, code: nil).memoryPressureLevel)
        XCTAssertEqual(sample(at: 0, percent: nil, code: 4).memoryPressureLevel, .critical)
    }

    func testHistoryFramePreparesTheMostSevereLevelOfEachBucket() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        // One sample a second for a minute: normal, one warning, then critical.
        let points = (0..<60).map { index -> MenuBarTelemetryPoint in
            let code = index == 10 ? 2 : (index < 30 ? 1 : 4)
            return sample(at: end.timeIntervalSince1970 - Double(59 - index), percent: index < 30 ? 40 : 90, code: code)
        }
        let plot = CGRect(x: 0, y: 0, width: 360, height: 100)
        let frame = GeekPreparedLineFrame(
            points: points, channels: [.memoryPressure], plot: plot, duration: 60, reference: end,
            samplingInterval: 1, scale: 2, stacked: true, valueRange: 0...100)
        XCTAssertEqual(frame.pressureLevels.count, frame.buckets.count)
        XCTAssertFalse(frame.buckets.isEmpty)
        var seen = Set<Int>()
        for (bucket, level) in zip(frame.buckets, frame.pressureLevels) {
            let expected = bucket.indices.compactMap { points[$0].memoryPressureLevel }.max { $0.severity < $1.severity }
            XCTAssertEqual(level, expected)
            if let level { seen.insert(level.severity) }
        }
        XCTAssertEqual(seen, [0, 1, 2], "each sample keeps its own level")

        // One hour is averaged in 30 s columns: a column holding a critical
        // sample among normal ones is critical.
        let hour = (0..<720).map { index in
            sample(at: end.timeIntervalSince1970 - Double(719 - index) * 5, percent: 50, code: index == 400 ? 4 : 1)
        }
        let averaged = GeekPreparedLineFrame(
            points: hour, channels: [.memoryPressure], plot: plot, duration: 3_600, reference: end,
            samplingInterval: 5, scale: 2, stacked: true, valueRange: 0...100)
        XCTAssertEqual(averaged.pressureLevels.count, averaged.buckets.count)
        let critical = zip(averaged.buckets, averaged.pressureLevels).filter { $0.1 == .critical }
        XCTAssertEqual(critical.count, 1)
        XCTAssertTrue(critical.first?.0.indices.contains(400) == true)
        XCTAssertGreaterThan(critical.first?.0.indices.count ?? 0, 1, "a mixed column")

        let cpu = GeekPreparedLineFrame(
            points: points, channels: [.cpuUser, .cpuSystem], plot: plot, duration: 60, reference: end,
            samplingInterval: 1, scale: 2, stacked: true, valueRange: 0...100)
        XCTAssertTrue(cpu.pressureLevels.isEmpty, "only the pressure channel carries levels")
    }

    @MainActor
    func testPressureHistoryDrawsEachBarInItsOwnLevelColor() throws {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        // The first five minutes normal at 40 %, the next five critical at
        // 90 %. D130 (2026-10-19): a history is one of iStat's windows, here
        // 10 minutes of 5 s buckets, one sample each; 60 s is no longer one
        // (was 60 samples 1 s apart, half normal, `duration: 60`).
        let points = (0..<120).map { index in
            sample(at: end.timeIntervalSince1970 - Double(119 - index) * 5,
                   percent: index < 60 ? 40 : 90, code: index < 60 ? 1 : 4)
        }
        let snapshot = memorySnapshot(headroom: 10, available: 0.1, compressed: 0.3, swapGiB: 4, measured: .critical)
        let scale: CGFloat = 2
        let width = MiniWindowStyleTokens.historyWidth - 2 * MiniWindowStyleTokens.contentInset
        let view = GeekMemoryHistoryHoverDetail(
            points: points, duration: 600, currentValue: "90%", pressure: "高", snapshot: snapshot
        )
        .environment(\.miniWindowPageProvidesInset, true)
        .frame(width: width)
        // Normal pressure in a color nothing else uses.
        .environment(\.panelMetricColors, PanelMetricColors(memoryPressure: "#00FF00"))
        .environment(\.miniWindowPreviewDate, end)
        .environment(\.colorScheme, .dark)
        .environment(\.miniWindowVisualMode, .black)
        .environment(\.displayScale, scale)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))

        let normal = try bounds(in: bitmap, scale: scale) { $0.green > 0.8 && $0.red < 0.3 && $0.blue < 0.3 }
        XCTAssertGreaterThan(normal.width, width * 0.35, "the normal half of the minute is drawn in the normal color")
        // Compare bars only: the legend dot above the plot has the current level's color.
        let band = normal.maxY - 30...normal.maxY - 2
        let critical = try bounds(in: bitmap, scale: scale, rows: band) { $0.red > 0.8 && $0.green < 0.45 && $0.blue < 0.45 }
        XCTAssertGreaterThan(critical.width, width * 0.35, "the critical half is drawn in the critical color")
        XCTAssertGreaterThanOrEqual(critical.minX, normal.maxX - 1, "older normal bars are not repainted by the current level")
    }

    func testThePressureDetailPassesTheLevelColorExit() throws {
        let detail = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let history = try MiniWindowLogicFixtures.section(
            detail, from: "struct GeekMemoryHistoryHoverDetail: View {", to: "struct GeekSwapDetailData")
        XCTAssertTrue(history.contains("pressureLevelColor: { metricColors.memoryPressure(for: $0) }"))
        // The ring and the legend keep the current level's color.
        XCTAssertTrue(history.contains("color: metricColors.memoryPressure(for: snapshot?.reportablePressureLevel)"))
        let probe = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Features/Memory/Infrastructure/SystemMemoryProbe.swift")
        XCTAssertFalse(probe.contains("MemoryPressurePolicy.classify"), "the probe no longer invents a level")
    }

#if DEBUG || STORAGE_CLEANER_BETA
    func testDemoHistoryCarriesTheDemoSnapshotLevel() {
        let arguments = [MiniWindowDemoData.launchArgument]
        let memory = MiniWindowDemoData.makeMemorySnapshot(arguments: arguments)
        let fixture = MiniWindowDemoData.makeFixture(arguments: arguments)
        XCTAssertNotNil(memory.reportablePressureLevel)
        XCTAssertTrue(fixture.telemetry.allSatisfy { $0.memoryPressureLevel == memory.reportablePressureLevel },
                      "the demo history is colored like the demo ring")
    }
#endif

    // MARK: - Fixtures

    private func memorySnapshot(
        headroom: Int?, available: Double, compressed: Double, swapGiB: Double, measured: MemoryPressureLevel?
    ) -> MemorySnapshot {
        let physical = 16 * gibibyte
        let availableBytes = Int64(Double(physical) * available)
        let compressedBytes = Int64(Double(physical) * compressed)
        let swapBytes = Int64(swapGiB * Double(gibibyte))
        let measurements = measured.map { level in
            MemoryMeasurements(
                pressure: .available(level),
                physicalBytes: .available(UInt64(physical)),
                availableBytes: .available(UInt64(availableBytes)),
                appBytes: .available(0),
                wiredBytes: .available(UInt64(gibibyte)),
                compressedBytes: .available(UInt64(compressedBytes)),
                cachedBytes: .available(0),
                swapUsedBytes: .available(UInt64(swapBytes)),
                swapInRate: .unavailable(.temporarilyInvalid, reason: "Not needed"),
                swapOutRate: .unavailable(.temporarilyInvalid, reason: "Not needed")
            )
        }
        return MemorySnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            physicalBytes: physical,
            freeBytes: availableBytes,
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: 0,
            purgeableBytes: 0,
            wiredBytes: gibibyte,
            compressedBytes: compressedBytes,
            swapUsedBytes: swapBytes,
            pressureFreePercentage: headroom,
            pressureSummary: "test",
            topProcesses: [],
            measurements: measurements
        )
    }

    private func sample(at time: TimeInterval, percent: Double?, code: Int?) -> MenuBarTelemetryPoint {
        MenuBarTelemetryPoint(
            date: Date(timeIntervalSince1970: time), cpuTotal: 20, cpuUser: 12, cpuSystem: 8, gpu: nil, memory: 50,
            memoryPressure: percent, memoryPressureLevelCode: code,
            chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil
        )
    }

    private struct Pixel { let red, green, blue: CGFloat }

    private func bounds(
        in bitmap: NSBitmapImageRep, scale: CGFloat, rows: ClosedRange<CGFloat>? = nil,
        matching: (Pixel) -> Bool
    ) throws -> CGRect {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            if let rows, !rows.contains(CGFloat(y) / scale) { continue }
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9,
                      matching(Pixel(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent))
                else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { throw MissingColor() }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private static func kernelPressureLevel() throws -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            throw XCTSkip("kern.memorystatus_vm_pressure_level is not readable on this system")
        }
        return value
    }
}

/// The drawing has no pixel of the expected color: a test failure.
private struct MissingColor: Error, CustomStringConvertible {
    var description: String { "no pixels of the expected color were drawn" }
}
