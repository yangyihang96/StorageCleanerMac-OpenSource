import Foundation
import XCTest
@testable import StorageCleanerMac

final class CPUPerformanceStateServiceTests: XCTestCase {
    func testSnapshotCoordinatorKeepsOnePhysicalWorkerAcrossCancellationStorm() async throws {
        let counter = LockedInvocationCounter()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let expected = snapshot(model: "single-flight")
        let coordinator = CPUPerformanceSnapshotCoordinator(
            timeout: .seconds(2),
            cooldown: .milliseconds(20)
        ) {
            counter.increment()
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            return expected
        }

        let survivor = Task { await coordinator.snapshot() }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

        let cancelledWaiters = (0..<32).map { _ in
            Task { await coordinator.snapshot() }
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        cancelledWaiters.forEach { $0.cancel() }
        for waiter in cancelledWaiters {
            let value = await waiter.value
            XCTAssertNil(value)
        }

        XCTAssertEqual(counter.value, 1)
        release.signal()
        let delivered = await survivor.value
        XCTAssertEqual(delivered, expected)
        XCTAssertEqual(counter.value, 1)
    }

    func testSnapshotCoordinatorDiscardsTimedOutResultAndCoolsDownWithoutWorkerPileup() async throws {
        let counter = LockedInvocationCounter()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stale = snapshot(model: "stale")
        let fresh = snapshot(model: "fresh")
        let coordinator = CPUPerformanceSnapshotCoordinator(
            timeout: .milliseconds(80),
            cooldown: .milliseconds(120)
        ) {
            let invocation = counter.increment()
            if invocation == 1 {
                started.signal()
                _ = release.wait(timeout: .now() + 2)
                return stale
            }
            return fresh
        }

        let timedOut = await coordinator.snapshot()
        XCTAssertNil(timedOut)
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

        let retryStorm = (0..<24).map { _ in
            Task { await coordinator.snapshot() }
        }
        for retry in retryStorm {
            let value = await retry.value
            XCTAssertNil(value)
        }
        XCTAssertEqual(counter.value, 1)

        release.signal()
        try await Task.sleep(for: .milliseconds(150))

        var delivered: CPUPerformanceStateService.Snapshot?
        for _ in 0..<20 where delivered == nil {
            delivered = await coordinator.snapshot()
            if delivered == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        XCTAssertEqual(delivered, fresh)
        XCTAssertEqual(counter.value, 2)
    }

    func testAdvancedMenuRefreshAwaitsSharedSnapshotWithoutDetachedIOReportWaiter() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Support/MenuBarAuxiliaryMonitorState.swift"
            ),
            encoding: .utf8
        )
        let refresh = try XCTUnwrap(
            source.components(separatedBy: "    private func refreshProcessorTelemetry").dropFirst().first?
                .components(separatedBy: "    private func cancelProcessorTelemetryRefresh").first
        )

        XCTAssertTrue(refresh.contains("await CPUPerformanceStateService.currentSnapshot()"))
        XCTAssertFalse(refresh.contains("Task.detached"))
    }

    func testDecodesHzAndMillivoltDVFSRecords() throws {
        let states = try XCTUnwrap(CPUPerformanceStateService.decodeDVFSStates(data([
            (2_064_000_000, 825),
            (3_228_000_000, 1_050)
        ])))

        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states[0].frequencyMHz, 2_064, accuracy: 0.001)
        XCTAssertEqual(states[0].voltageVolts, 0.825, accuracy: 0.000_001)
        XCTAssertEqual(states[1].frequencyMHz, 3_228, accuracy: 0.001)
        XCTAssertEqual(states[1].voltageVolts, 1.05, accuracy: 0.000_001)
    }

    func testDecodesKHzAndMicrovoltDVFSRecords() throws {
        let states = try XCTUnwrap(CPUPerformanceStateService.decodeDVFSStates(data([
            (0, 0),
            (1_344_000, 765_000),
            (4_500_000, 1_120_000),
            (0, 0)
        ])))

        XCTAssertEqual(states.map(\.frequencyMHz), [1_344, 4_500])
        XCTAssertEqual(states[0].voltageVolts, 0.765, accuracy: 0.000_001)
        XCTAssertEqual(states[1].voltageVolts, 1.12, accuracy: 0.000_001)
    }

    func testDVFSDecoderFailsClosedForMalformedOrImplausibleRecords() {
        XCTAssertNil(CPUPerformanceStateService.decodeDVFSStates(Data()))
        XCTAssertNil(CPUPerformanceStateService.decodeDVFSStates(Data(repeating: 0, count: 7)))
        XCTAssertNil(CPUPerformanceStateService.decodeDVFSStates(data([(0, 800)])))
        XCTAssertNil(CPUPerformanceStateService.decodeDVFSStates(data([(2_000_000, 0)])))
        XCTAssertNil(CPUPerformanceStateService.decodeDVFSStates(data([(20_000_000, 800)])))
        XCTAssertNil(CPUPerformanceStateService.decodeDVFSStates(data([
            (2_000_000, 900),
            (1_000_000, 800)
        ])))
    }

    func testDecodesM5ACCClusterVoltageStateIndicesWithoutAssumingTierOrder() {
        let bytes: [UInt8] = [
            22, 0, 0, 0, 0, 0, 0, 0,
            23, 1, 0, 0, 0, 0, 0, 0,
            5, 2, 0, 0, 0, 0, 0, 0
        ]

        XCTAssertEqual(
            CPUPerformanceStateService.decodeACCClusterVoltageStateIndices(Data(bytes)),
            [22, 23, 5]
        )
    }

    func testACCClusterDecoderRejectsTruncationAndDuplicateIndices() {
        XCTAssertNil(CPUPerformanceStateService.decodeACCClusterVoltageStateIndices(Data()))
        XCTAssertNil(CPUPerformanceStateService.decodeACCClusterVoltageStateIndices(Data([1, 0])))
        XCTAssertNil(CPUPerformanceStateService.decodeACCClusterVoltageStateIndices(Data([
            5, 0, 0, 0, 0, 0, 0, 0,
            5, 1, 0, 0, 0, 0, 0, 0
        ])))
    }

    func testWeightsFrequencyAndNominalVoltageAcrossActiveStates() throws {
        let point = try XCTUnwrap(CPUPerformanceStateService.weightedOperatingPoint(
            residencies: [
                .init(name: "DOWN", value: 1_000),
                .init(name: "V0P1", value: 20),
                .init(name: "V1P0", value: 80),
                .init(name: "IDLE", value: 500)
            ],
            states: [
                .init(frequencyMHz: 1_000, voltageVolts: 0.7),
                .init(frequencyMHz: 3_000, voltageVolts: 1.1)
            ]
        ))

        XCTAssertEqual(point.frequencyMHz, 2_600, accuracy: 0.001)
        XCTAssertEqual(point.voltageVolts, 1.02, accuracy: 0.000_001)
    }

    func testHidesOperatingPointWhenAllActiveResidenciesAreZero() {
        let residencies = [
            CPUPerformanceStateService.StateResidency(name: "IDLE", value: 10_000),
            CPUPerformanceStateService.StateResidency(name: "V0P1", value: 0),
            CPUPerformanceStateService.StateResidency(name: "V1P0", value: 0)
        ]
        let states = [
            CPUPerformanceStateService.DVFSState(frequencyMHz: 1_200, voltageVolts: 0.75),
            CPUPerformanceStateService.DVFSState(frequencyMHz: 3_200, voltageVolts: 1.05)
        ]
        XCTAssertNil(CPUPerformanceStateService.weightedOperatingPoint(
            residencies: residencies,
            states: states
        ))
        XCTAssertEqual(CPUPerformanceStateService.isIdleOperatingState(
            residencies: residencies,
            states: states
        ), true)
    }

    func testWeightedOperatingPointRejectsStateCountMismatch() {
        XCTAssertNil(CPUPerformanceStateService.weightedOperatingPoint(
            residencies: [
                .init(name: "V0P1", value: 10),
                .init(name: "V1P0", value: 20)
            ],
            states: [.init(frequencyMHz: 1_000, voltageVolts: 0.7)]
        ))
    }

    func testWeightedOperatingPointRejectsUnknownOrReorderedStateNames() {
        let states = [
            CPUPerformanceStateService.DVFSState(frequencyMHz: 1_000, voltageVolts: 0.7),
            CPUPerformanceStateService.DVFSState(frequencyMHz: 2_000, voltageVolts: 0.9)
        ]
        XCTAssertNil(CPUPerformanceStateService.weightedOperatingPoint(
            residencies: [
                .init(name: "P1", value: 10),
                .init(name: "P2", value: 20)
            ],
            states: states
        ))
        XCTAssertNil(CPUPerformanceStateService.weightedOperatingPoint(
            residencies: [
                .init(name: "V1P0", value: 10),
                .init(name: "V0P1", value: 20)
            ],
            states: states
        ))
    }

    func testMapsM5PCPUAndMCPUClustersFromStateShapeAndPerflevelTopology() throws {
        let superTable = table("voltage-states5-sram", [1_400, 4_500])
        let middleTableA = table("voltage-states22-sram", [1_300, 2_400, 3_900])
        let middleTableB = table("voltage-states23-sram", [1_300, 2_400, 3_900])
        let levels = [
            CPUPerformanceStateService.PerformanceLevel(
                index: 0, name: "Super", coreCount: 6, coresPerL2: 6
            ),
            CPUPerformanceStateService.PerformanceLevel(
                index: 1, name: "Performance", coreCount: 12, coresPerL2: 6
            )
        ]
        let channels = [
            channel("MCPU1", activeCount: 3),
            channel("PCPU", activeCount: 2),
            channel("MCPU0", activeCount: 3)
        ]

        let assignments = try XCTUnwrap(CPUPerformanceStateService.makeClusterAssignments(
            channels: channels,
            tables: [middleTableB, superTable, middleTableA],
            performanceLevels: levels.reversed()
        ))

        XCTAssertEqual(assignments.map(\.channelIdentifier), ["PCPU", "MCPU0", "MCPU1"])
        XCTAssertEqual(assignments.map(\.performanceLevel.name), ["Super", "Performance", "Performance"])
        XCTAssertEqual(assignments.map(\.coreCount), [6, 6, 6])
    }

    func testMapsOlderECPUAndPCPUWithoutUsingInputOrder() throws {
        let low = table("voltage-states1-sram", [600, 1_200])
        let high = table("voltage-states5-sram", [1_200, 2_400, 3_200])
        let levels = [
            CPUPerformanceStateService.PerformanceLevel(
                index: 1, name: "Efficiency", coreCount: 4, coresPerL2: 4
            ),
            CPUPerformanceStateService.PerformanceLevel(
                index: 0, name: "Performance", coreCount: 8, coresPerL2: 4
            )
        ]

        let assignments = try XCTUnwrap(CPUPerformanceStateService.makeClusterAssignments(
            channels: [channel("ECPU", activeCount: 2), channel("PCPU1", activeCount: 3), channel("PCPU", activeCount: 3)],
            tables: [high, low],
            performanceLevels: levels
        ))

        XCTAssertEqual(assignments.map(\.channelIdentifier), ["PCPU", "PCPU1", "ECPU"])
        XCTAssertEqual(assignments.map(\.performanceLevel.name), ["Performance", "Performance", "Efficiency"])
    }

    func testClusterMappingFailsClosedForAmbiguousTablesAndTopologyMismatch() {
        let levels = [CPUPerformanceStateService.PerformanceLevel(
            index: 0, name: "Performance", coreCount: 4, coresPerL2: 4
        )]
        let pcpuChannel = channel("PCPU", activeCount: 2)
        let first = table("voltage-states1-sram", [1_000, 2_000])
        let conflicting = table("voltage-states5-sram", [1_200, 3_000])

        XCTAssertNil(CPUPerformanceStateService.makeClusterAssignments(
            channels: [pcpuChannel],
            tables: [first, conflicting],
            performanceLevels: levels
        ))

        XCTAssertNil(CPUPerformanceStateService.makeClusterAssignments(
            channels: [channel("PCPU", activeCount: 2), channel("PCPU1", activeCount: 2)],
            tables: [first],
            performanceLevels: levels
        ))
    }

    func testStaticSnapshotReportsLocalAppleSiliconTopologyWhenAvailable() throws {
        guard let snapshot = CPUPerformanceStateService.staticSnapshot() else {
            throw XCTSkip("Apple Silicon pmgr DVFS metadata is unavailable in this environment")
        }
        XCTAssertFalse(snapshot.processorModel.isEmpty)
        XCTAssertFalse(snapshot.performanceLevels.isEmpty)
        XCTAssertTrue(snapshot.clusters.isEmpty)
    }

    func testCurrentSnapshotSeedsThenReadsLocalIOReportDeltaWhenAvailable() async throws {
        guard CPUPerformanceStateService.staticSnapshot() != nil else {
            throw XCTSkip("Apple Silicon topology is unavailable in this environment")
        }

        let seeded = await CPUPerformanceStateService.currentSnapshot()
        XCTAssertNil(seeded)
        try await Task.sleep(for: .milliseconds(20))
        guard let snapshot = await CPUPerformanceStateService.currentSnapshot() else {
            throw XCTSkip("Private IOReport CPU state channels are unavailable in this environment")
        }
        XCTAssertFalse(snapshot.clusters.isEmpty)
        XCTAssertTrue(snapshot.clusters.allSatisfy {
            switch ($0.frequencyMHz, $0.voltageVolts) {
            case let (.some(frequency), .some(voltage)):
                frequency >= 300 && voltage >= 0.4
            case (nil, nil):
                true
            default:
                false
            }
        })
    }

    private func data(_ records: [(UInt32, UInt32)]) -> Data {
        var result = Data()
        for (frequency, voltage) in records {
            withUnsafeBytes(of: frequency.littleEndian) { result.append(contentsOf: $0) }
            withUnsafeBytes(of: voltage.littleEndian) { result.append(contentsOf: $0) }
        }
        return result
    }

    private func snapshot(model: String) -> CPUPerformanceStateService.Snapshot {
        CPUPerformanceStateService.Snapshot(
            processorModel: model,
            performanceLevels: [],
            clusters: []
        )
    }

    private func table(_ source: String, _ frequencies: [Double]) -> CPUPerformanceStateService.DVFSTable {
        .init(
            sourceKey: source,
            states: frequencies.enumerated().map {
                .init(frequencyMHz: $0.element, voltageVolts: 0.7 + Double($0.offset) * 0.1)
            }
        )
    }

    private func channel(_ identifier: String, activeCount: Int) -> CPUPerformanceStateService.ClusterStateChannel {
        .init(
            identifier: identifier,
            residencies: [.init(name: "IDLE", value: 1_000)] + (0..<activeCount).map {
                .init(name: "P\($0 + 1)", value: UInt64($0 + 1))
            }
        )
    }
}

private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}
