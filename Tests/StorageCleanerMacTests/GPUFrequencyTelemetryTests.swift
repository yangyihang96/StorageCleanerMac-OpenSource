import Foundation
import XCTest
@testable import StorageCleanerMac

/// BOARD N16-1 (live 2026-10-07): the CPU page's frequency rows showed
/// "GPU 频率 —" and the GPU rings had no frequency, while iStat Menus showed
/// 0.34 GHz on the same Mac. The row was a fixed placeholder: nothing read
/// the GPU. It now reads IOReport's GPU performance states (GPUPH) against
/// the pmgr GPU DVFS table, the way the CPU clusters are read.
@MainActor
final class GPUFrequencyTelemetryTests: XCTestCase {
    /// The shape of `voltage-states9` on the M5 Pro this was found on:
    /// a powered-off record (0 Hz, 125 mV) and ascending operating points.
    private let m5ProTable: [(UInt32, UInt32)] = [
        (0, 125), (338_000_000, 580), (486_000_000, 625), (636_000_000, 660),
        (796_000_000, 705), (888_000_000, 715), (988_000_000, 745), (1_084_000_000, 770),
        (1_182_000_000, 800), (1_278_000_000, 850), (1_374_000_000, 875), (1_470_000_000, 920),
        (1_578_000_000, 995), (1_620_000_000, 1_020),
    ]

    func testTheGPUTableKeepsItsPoweredOffRecordOutOfTheOperatingPoints() throws {
        let states = try XCTUnwrap(CPUPerformanceStateService.decodeGPUDVFSStates(data(m5ProTable)))
        XCTAssertEqual(states.count, 13)
        XCTAssertEqual(states.first?.frequencyMHz ?? 0, 338, accuracy: 0.001)
        XCTAssertEqual(states.first?.voltageVolts ?? 0, 0.58, accuracy: 0.000_001)
        XCTAssertEqual(states.last?.frequencyMHz ?? 0, 1_620, accuracy: 0.001)
        // The CPU decoder rejects this table (its 0 Hz record has a voltage).
        XCTAssertNil(CPUPerformanceStateService.decodeDVFSStates(data(m5ProTable)))
        // A table without the powered-off record is read the same way.
        XCTAssertEqual(
            CPUPerformanceStateService.decodeGPUDVFSStates(data(Array(m5ProTable.dropFirst())))?.count, 13)
    }

    /// r2-live-fixes-2 review P2-4: an all-zero record is padding only at the
    /// end. One between operating points used to be skipped, which shifted
    /// every later P state onto the wrong clock ([off, 338, (0,0), 486, 636]
    /// read as [338, 486, 636], P2 as 486 MHz).
    func testAZeroRecordIsPaddingOnlyAtTheEndOfTheGPUTable() throws {
        XCTAssertNil(CPUPerformanceStateService.decodeGPUDVFSStates(data([
            (0, 125), (338_000_000, 580), (0, 0), (486_000_000, 625), (636_000_000, 660),
        ])), "a zero record between operating points")
        XCTAssertNil(CPUPerformanceStateService.decodeGPUDVFSStates(data([
            (0, 125), (0, 0), (338_000_000, 580), (486_000_000, 625),
        ])), "a zero record before the first operating point")
        let padded = try XCTUnwrap(CPUPerformanceStateService.decodeGPUDVFSStates(data(
            m5ProTable + [(0, 0), (0, 0), (0, 0)])), "trailing padding")
        XCTAssertEqual(padded.map(\.frequencyMHz), m5ProTable.dropFirst().map { Double($0.0) / 1_000_000 })
    }

    func testTheGPUTableFailsClosedForMalformedRecords() {
        XCTAssertNil(CPUPerformanceStateService.decodeGPUDVFSStates(Data()))
        XCTAssertNil(CPUPerformanceStateService.decodeGPUDVFSStates(Data(repeating: 0, count: 7)))
        XCTAssertNil(CPUPerformanceStateService.decodeGPUDVFSStates(data([(0, 125)])), "no operating point")
        XCTAssertNil(CPUPerformanceStateService.decodeGPUDVFSStates(data([
            (0, 125), (338_000_000, 580), (0, 125), (486_000_000, 625),
        ])), "a powered-off record between operating points")
        XCTAssertNil(CPUPerformanceStateService.decodeGPUDVFSStates(data([
            (0, 125), (486_000_000, 625), (338_000_000, 580),
        ])), "descending frequencies")
        XCTAssertNil(CPUPerformanceStateService.decodeGPUDVFSStates(data([
            (0, 125), (338_000_000, 580), (4_000_000_000, 700),
        ])), "an implausible GPU clock")
    }

    func testTheFrequencyIsTheResidencyWeightedActiveFrequency() throws {
        let states = try XCTUnwrap(CPUPerformanceStateService.decodeGPUDVFSStates(data(m5ProTable)))
        let reading = try XCTUnwrap(CPUPerformanceStateService.gpuReading(
            residencies: residencies(off: 1_000, active: [900, 100]), states: states))
        XCTAssertEqual(reading.frequencyMHz ?? 0, (900 * 338 + 100 * 486) / 1_000, accuracy: 0.001)
        XCTAssertEqual(reading.activeRatio, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(reading.maximumFrequencyMHz, 1_620, accuracy: 0.001)
    }

    func testAGPUThatWasOffTheWholeIntervalIsIdleNotZero() throws {
        let states = try XCTUnwrap(CPUPerformanceStateService.decodeGPUDVFSStates(data(m5ProTable)))
        let reading = try XCTUnwrap(CPUPerformanceStateService.gpuReading(
            residencies: residencies(off: 2_000, active: []), states: states))
        XCTAssertNil(reading.frequencyMHz)
        XCTAssertEqual(reading.activeRatio, 0)
    }

    func testStatesTheTableCannotMapFailClosed() throws {
        let states = try XCTUnwrap(CPUPerformanceStateService.decodeGPUDVFSStates(data(m5ProTable)))
        // GPUPH has fifteen P states; this table has thirteen operating points.
        var beyond = residencies(off: 10, active: [5])
        beyond[14] = .init(name: "P14", value: 1)
        XCTAssertNil(CPUPerformanceStateService.gpuReading(residencies: beyond, states: states),
                     "time in a state without an operating point")
        XCTAssertNotNil(CPUPerformanceStateService.gpuReading(
            residencies: residencies(off: 10, active: [5]), states: states),
                        "unused states beyond the table are fine")
        var renamed = residencies(off: 10, active: [5])
        renamed[2] = .init(name: "P3", value: 0)
        XCTAssertNil(CPUPerformanceStateService.gpuReading(residencies: renamed, states: states),
                     "states out of order")
        XCTAssertNil(CPUPerformanceStateService.gpuReading(
            residencies: Array(residencies(off: 10, active: [5]).prefix(5)), states: states),
                     "fewer states than operating points")
        XCTAssertNil(CPUPerformanceStateService.gpuReading(residencies: [], states: states))
    }

    func testThePresentationShowsTheReadingIdleOrWhyThereIsNone() {
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        defer { chinese.restore() }
        let reading = CPUPerformanceStateService.GPUReading(
            frequencyMHz: 338, activeRatio: 0.9, maximumFrequencyMHz: 1_620)
        XCTAssertEqual(GeekGPUFrequencyPresentation.value(reading), "0.34 GHz")
        let sampledAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let row = GeekGPUFrequencyPresentation.readout(reading, sampledAt: sampledAt)
        XCTAssertEqual(row.value, "0.34 GHz")
        XCTAssertEqual(row.source, "IOReport")
        XCTAssertEqual(row.sampledAt, sampledAt)

        let idle = CPUPerformanceStateService.GPUReading(frequencyMHz: nil, activeRatio: 0, maximumFrequencyMHz: 1_620)
        XCTAssertEqual(GeekGPUFrequencyPresentation.value(idle), "空闲")
        XCTAssertEqual(GeekGPUFrequencyPresentation.readout(idle, sampledAt: sampledAt).value, "空闲")
        XCTAssertTrue(GeekGPUFrequencyPresentation.readout(idle, sampledAt: sampledAt).note.contains("关闭"))

        let missing = GeekGPUFrequencyPresentation.readout(nil, sampledAt: sampledAt)
        XCTAssertEqual(missing.value, "—")
        XCTAssertNil(missing.sampledAt)
        XCTAssertTrue(missing.note.contains("未能读取"), missing.note)
    }

    /// The GPU rings and rows read the presentation; none keeps a fixed "—".
    func testTheGPURingsAndTheFrequencyRowReadTheReading() throws {
        let sensors = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift")
        // User 2026-10-11 (e): a missing reading adds no "—" row; a present one reads the presentation.
        XCTAssertTrue(sensors.contains("if let gpu = telemetry?.gpu"))
        XCTAssertTrue(sensors.contains("GeekGPUFrequencyPresentation.readout(gpu, sampledAt: sampledAt)"))
        XCTAssertFalse(sensors.contains("本机当前没有经过验证的 GPU 时钟读数"))
        let processor = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift")
        let gpuCard = try MiniWindowLogicFixtures.section(
            processor, from: "private var geekProcessorGPUCard: some View {", to: "private var geekProcessorGPUHoverTarget")
        XCTAssertTrue(gpuCard.contains("geekProcessorGPUFrequencyRing"), "the GPU card has a frequency ring (iStat)")
        let overview = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekOverviewPresentation.swift")
        let sensorsCard = try MiniWindowLogicFixtures.section(
            overview, from: "struct GeekSensorsPresentation: View {", to: "private extension View")
        XCTAssertTrue(sensorsCard.contains("geekCompactGPUFrequencyText"), "the overview GPU ring shows its frequency")
    }

    /// The real path on this Mac: two IOReport samples give a GPU reading
    /// (idle or a frequency inside the table).
    func testTheLocalGPUIsReadWhenAvailable() async throws {
        guard CPUPerformanceStateService.staticSnapshot() != nil else {
            throw XCTSkip("Apple Silicon topology is unavailable in this environment")
        }
        _ = await CPUPerformanceStateService.currentSnapshot()
        try await Task.sleep(for: .milliseconds(200))
        guard let snapshot = await CPUPerformanceStateService.currentSnapshot() else {
            throw XCTSkip("IOReport state channels are unavailable in this environment")
        }
        let gpu = try XCTUnwrap(snapshot.gpu, "the GPU performance states are read with the CPU's")
        print("GPU reading on this Mac: frequency \(gpu.frequencyMHz.map { String(format: "%.1f MHz", $0) } ?? "idle"), active \(String(format: "%.2f", gpu.activeRatio)), highest \(gpu.maximumFrequencyMHz) MHz")
        XCTAssertTrue((0...1).contains(gpu.activeRatio))
        if let frequency = gpu.frequencyMHz {
            XCTAssertGreaterThan(frequency, 100)
            XCTAssertLessThanOrEqual(frequency, gpu.maximumFrequencyMHz + 0.001)
        }
    }

    private func residencies(off: UInt64, active: [UInt64]) -> [CPUPerformanceStateService.StateResidency] {
        [.init(name: "OFF", value: off)] + (1...15).map { index in
            .init(name: "P\(index)", value: index <= active.count ? active[index - 1] : 0)
        }
    }

    private func data(_ records: [(UInt32, UInt32)]) -> Data {
        var result = Data()
        for (frequency, voltage) in records {
            withUnsafeBytes(of: frequency.littleEndian) { result.append(contentsOf: $0) }
            withUnsafeBytes(of: voltage.littleEndian) { result.append(contentsOf: $0) }
        }
        return result
    }
}
