import Foundation
import XCTest
@testable import StorageCleanerMac

/// DECISIONS D57 ①, research §4.2: the Energy Model's mJ counters advance in
/// batches about every 2.1 s (GPU Energy, nJ, every sample). Dividing each
/// sampling window's energy by the window showed 0 W and 2–3× spikes. Power
/// is now energy between two counter updates over the time between them.
final class SoCPowerEstimatorTests: XCTestCase {
    // MARK: - Cadence

    /// Mac17,9's measured batch period with a little jitter; sampled at the
    /// page's 2 s, a jittery 1.7–2.5 s, 1 s, and the slowest refresh 5 s.
    func testBatchedCountersNeverShowZeroOrMultipleSpikes() throws {
        let schedules: [(String, [Double])] = [
            ("2 s", stride(from: 0.37, to: 120, by: 2.0).map { $0 }),
            ("jitter", jitteredTimes(start: 0.11, until: 120, range: 1.7...2.5)),
            ("1 s", stride(from: 0.53, to: 60, by: 1.0).map { $0 }),
            ("5 s", stride(from: 0.29, to: 200, by: 5.0).map { $0 }),
        ]
        for (label, times) in schedules {
            var estimator = SoCPowerEstimator()
            var shown = 0
            var updating = 0
            for (index, time) in times.enumerated() {
                let powers = estimator.update(counters: counters(at: time), sampledAt: time)
                let cpu = try XCTUnwrap(powers["CPU Energy"], label)
                let gpu = try XCTUnwrap(powers["GPU Energy"], label)
                let ane = try XCTUnwrap(powers["ANE0"], label)
                if index == 0 {
                    XCTAssertNil(cpu.watts, "\(label): the first window has no value yet")
                    XCTAssertTrue(cpu.isUpdating, "\(label): the first window is marked updating")
                    continue
                }
                let hadBatch = batchTimes.contains { $0 > times[index - 1] && $0 <= time }
                if let watts = cpu.watts {
                    XCTAssertNotEqual(watts, 0, "\(label) t=\(time): no artificial 0 W")
                    XCTAssertEqual(watts, Self.cpuWatts, accuracy: Self.cpuWatts * 0.01,
                                   "\(label) t=\(time): no multiple spike or dip")
                    shown += 1
                } else {
                    // Only possible before the first batch after the start.
                    XCTAssertFalse(batchTimes.contains { $0 > times[0] && $0 <= times[index - 1] }, "\(label) t=\(time)")
                }
                XCTAssertEqual(cpu.isUpdating, !hadBatch, "\(label) t=\(time): updating exactly without a new count")
                if cpu.isUpdating { updating += 1 }
                XCTAssertEqual(try XCTUnwrap(gpu.watts, label), Self.gpuWatts, accuracy: Self.gpuWatts * 0.01)
                if hadBatch {
                    XCTAssertEqual(ane.watts, 0, "\(label): an idle Neural Engine is a legal 0 W")
                    XCTAssertFalse(ane.isUpdating)
                }
            }
            XCTAssertGreaterThan(shown, times.count / 2, label)
            if label == "5 s" { XCTAssertEqual(updating, 0, "every 5 s window holds a batch") }
        }
    }

    func testTheNaiveWindowDivisionWouldHaveFlickered() {
        // The research's observation, reproduced on the same fixture: a
        // 1 s window divided by its own length.
        let times = stride(from: 0.53, to: 30, by: 1.0).map { $0 }
        var values: [Double] = []
        for (previous, time) in zip(times, times.dropFirst()) {
            let energy = Double(counters(at: time)[0].value - counters(at: previous)[0].value) * 1e-3
            values.append(energy / (time - previous))
        }
        XCTAssertTrue(values.contains(0))
        XCTAssertTrue(values.contains { $0 > Self.cpuWatts * 1.9 })
    }

    func testCounterResetStartsANewBaselineWithoutASpike() throws {
        var estimator = SoCPowerEstimator()
        _ = estimator.update(counters: [counter("CPU Energy", 1_000_000, at: 1.0)], sampledAt: 1.2)
        let normal = estimator.update(counters: [counter("CPU Energy", 1_020_000, at: 3.0)], sampledAt: 3.2)
        XCTAssertEqual(try XCTUnwrap(normal["CPU Energy"]?.watts), 10, accuracy: 0.001)
        // Lower than before: a reset, not negative or huge power.
        let reset = try XCTUnwrap(estimator.update(counters: [counter("CPU Energy", 5_000, at: 5.0)], sampledAt: 5.2)["CPU Energy"])
        XCTAssertTrue(reset.isUpdating)
        XCTAssertEqual(reset.watts, 10, "keeps the last value while re-baselining")
        let after = try XCTUnwrap(estimator.update(counters: [counter("CPU Energy", 25_000, at: 7.0)], sampledAt: 7.2)["CPU Energy"])
        XCTAssertEqual(try XCTUnwrap(after.watts), 10, accuracy: 0.001)
        XCTAssertFalse(after.isUpdating)
    }

    func testAForcedResampleMillisecondsLaterDoesNotDivideATinyWindow() throws {
        var estimator = SoCPowerEstimator()
        let gpu = { (nanojoules: Int64, time: Double) in
            SoCEnergyCounter(name: "GPU Energy", unitLabel: "nJ", value: nanojoules, updatedAt: time)
        }
        _ = estimator.update(counters: [gpu(0, 10.0)], sampledAt: 10.0)
        let steady = try XCTUnwrap(estimator.update(counters: [gpu(1_000_000_000, 12.0)], sampledAt: 12.0)["GPU Energy"])
        XCTAssertEqual(try XCTUnwrap(steady.watts), 0.5, accuracy: 0.0001)
        // 10 ms later a burst of 0.05 J would read 5 W over the tiny window.
        let forced = try XCTUnwrap(estimator.update(counters: [gpu(1_050_000_000, 12.01)], sampledAt: 12.01)["GPU Energy"])
        XCTAssertEqual(try XCTUnwrap(forced.watts), 0.5, accuracy: 0.0001, "the previous window stands")
        let next = try XCTUnwrap(estimator.update(counters: [gpu(2_050_000_000, 14.0)], sampledAt: 14.0)["GPU Energy"])
        XCTAssertEqual(try XCTUnwrap(next.watts), 0.525, accuracy: 0.0001, "the next window spans both")
    }

    func testImplausiblePowerIsInvalidNotShown() throws {
        var estimator = SoCPowerEstimator()
        _ = estimator.update(counters: [counter("CPU Energy", 0, at: 1.0)], sampledAt: 1.1)
        // 5 000 J in 2 s = 2.5 kW.
        let power = try XCTUnwrap(estimator.update(counters: [counter("CPU Energy", 5_000_000, at: 3.0)], sampledAt: 3.1)["CPU Energy"])
        XCTAssertTrue(power.isInvalid)
        XCTAssertNil(power.watts)
    }

    func testPausingKeepsTheLastValuesMarkedUpdatingUntilANewWindow() throws {
        var estimator = SoCPowerEstimator()
        _ = estimator.update(counters: [counter("CPU Energy", 0, at: 1.0)], sampledAt: 1.1)
        _ = estimator.update(counters: [counter("CPU Energy", 20_000, at: 3.0)], sampledAt: 3.1)
        estimator.reset()
        // Minutes later: the first sample is a new baseline, not one window
        // spanning the hidden time.
        let first = try XCTUnwrap(estimator.update(counters: [counter("CPU Energy", 9_000_000, at: 300.0)], sampledAt: 300.1)["CPU Energy"])
        XCTAssertEqual(first.watts, 10)
        XCTAssertTrue(first.isUpdating)
        let next = try XCTUnwrap(estimator.update(counters: [counter("CPU Energy", 9_042_000, at: 302.1)], sampledAt: 302.2)["CPU Energy"])
        XCTAssertEqual(try XCTUnwrap(next.watts), 20, accuracy: 0.001)
        XCTAssertFalse(next.isUpdating)
    }

    /// Review item 4: no pause arrives (or it comes late) and no sample is
    /// taken for a minute; the next window must not be that minute's
    /// average. A gap over 10 s starts a new baseline.
    func testAGapOfMoreThanTenSecondsBetweenSamplesStartsANewBaseline() throws {
        var estimator = SoCPowerEstimator()
        // 10 W, sampled every 2 s until 20 s.
        for step in 0...10 {
            let time = Double(step) * 2
            _ = estimator.update(counters: [counter("CPU Energy", Int64(step) * 20_000, at: time)], sampledAt: time + 0.1)
        }
        // No sample from 20.1 s to 80.1 s: 1 W until 78 s, then 30 W.
        let first = try XCTUnwrap(estimator.update(
            counters: [counter("CPU Energy", 318_000, at: 80)], sampledAt: 80.1
        )["CPU Energy"])
        XCTAssertEqual(first.watts, 10, "the last value, not the gap's 1.97 W average")
        XCTAssertTrue(first.isUpdating)
        let next = try XCTUnwrap(estimator.update(
            counters: [counter("CPU Energy", 378_000, at: 82)], sampledAt: 82.1
        )["CPU Energy"])
        XCTAssertEqual(try XCTUnwrap(next.watts), 30, accuracy: 0.001)
        XCTAssertFalse(next.isUpdating)

        // A 9.9 s gap is still one window.
        var steady = SoCPowerEstimator()
        _ = steady.update(counters: [counter("CPU Energy", 0, at: 0)], sampledAt: 0.1)
        let within = try XCTUnwrap(steady.update(counters: [counter("CPU Energy", 99_000, at: 9.9)], sampledAt: 10.0)["CPU Energy"])
        XCTAssertEqual(try XCTUnwrap(within.watts), 10, accuracy: 0.001)
        XCTAssertFalse(within.isUpdating)
    }

    /// The counters' clock (mach_absolute_time) stops while the system
    /// sleeps; the gap is measured on a clock that does not.
    func testSleepIsNoticedOnTheContinuousClock() throws {
        var estimator = SoCPowerEstimator()
        _ = estimator.update(counters: [counter("CPU Energy", 0, at: 1)], sampledAt: 1.1, continuousClock: 1.1)
        _ = estimator.update(counters: [counter("CPU Energy", 20_000, at: 3)], sampledAt: 3.1, continuousClock: 3.1)
        // An hour asleep: 2 s on the counters' clock, 3 600 s on the
        // continuous one; the counter took in 18 J meanwhile.
        let afterWake = try XCTUnwrap(estimator.update(
            counters: [counter("CPU Energy", 58_000, at: 5)], sampledAt: 5.1, continuousClock: 3_605.1
        )["CPU Energy"])
        XCTAssertEqual(afterWake.watts, 10, "not 19 W from the energy taken in while asleep")
        XCTAssertTrue(afterWake.isUpdating)
        let next = try XCTUnwrap(estimator.update(
            counters: [counter("CPU Energy", 66_000, at: 7)], sampledAt: 7.1, continuousClock: 3_607.1
        )["CPU Energy"])
        XCTAssertEqual(try XCTUnwrap(next.watts), 4, accuracy: 0.001)
        XCTAssertFalse(next.isUpdating)

        let sampler = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Services/SoCPowerTelemetry.swift")
        XCTAssertTrue(sampler.contains("continuousClock: reader.continuousNow()"), "the sampler passes the continuous clock")
        let reader = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Services/CPUPerformanceStateService.swift")
        XCTAssertTrue(reader.contains("Double(mach_continuous_time()) * ticksToSeconds"))
    }

    func testLosingTimestampsLaterStartsTheFallbackWindowAtTheLastUpdate() throws {
        var estimator = SoCPowerEstimator()
        _ = estimator.update(counters: [counter("CPU Energy", 0, at: 1.0)], sampledAt: 1.1)
        // A long run of timestamped updates at 10 W …
        for step in 1...30 {
            let time = 1.0 + Double(step) * 2.0
            _ = estimator.update(counters: [counter("CPU Energy", Int64(step) * 20_000, at: time)], sampledAt: time + 0.1)
        }
        // … then the load triples while timestamps become unreadable. The
        // fallback window starts at the last update (61.1 s), not at the
        // first baseline: until it spans 8 s the last exact value is kept and
        // marked; then it reads the new 30 W, not a minute-long average.
        var powers: [SoCChannelPower] = []
        for step in 1...4 {
            // 30 W over 2.1 s steps: 63 J each.
            let value = 600_000 + Int64(step) * 63_000
            powers.append(try XCTUnwrap(estimator.update(
                counters: [SoCEnergyCounter(name: "CPU Energy", unitLabel: "mJ", value: value, updatedAt: nil)],
                sampledAt: 61.1 + Double(step) * 2.1
            )["CPU Energy"]))
        }
        for power in powers.prefix(3) {
            XCTAssertEqual(try XCTUnwrap(power.watts), 10, accuracy: 0.001)
            XCTAssertTrue(power.isUpdating)
        }
        XCTAssertEqual(try XCTUnwrap(powers[3].watts), 30, accuracy: 0.001)
        XCTAssertFalse(powers[3].isUpdating)
    }

    func testUnknownUnitsAreNotGuessed() {
        var estimator = SoCPowerEstimator()
        let counters = [SoCEnergyCounter(name: "CPU Energy", unitLabel: "W", value: 1, updatedAt: 1)]
        XCTAssertTrue(estimator.update(counters: counters, sampledAt: 1).isEmpty)
    }

    /// Without readable update timestamps the estimator falls back to
    /// count changes over a window of at least 8 s (D57: "≥ 4 s"): still no
    /// 0 W and no 2–3× spikes, at a coarser accuracy.
    func testWindowFallbackWithoutTimestampsAlsoAvoidsZeroAndSpikes() throws {
        for (label, times) in [
            ("2 s", stride(from: 0.37, to: 120, by: 2.0).map { $0 }),
            ("1 s", stride(from: 0.53, to: 60, by: 1.0).map { $0 }),
        ] {
            var estimator = SoCPowerEstimator()
            var shown = 0
            for time in times {
                let counters = counters(at: time).map {
                    SoCEnergyCounter(name: $0.name, unitLabel: $0.unitLabel, value: $0.value, updatedAt: nil)
                }
                let power = try XCTUnwrap(estimator.update(counters: counters, sampledAt: time)["CPU Energy"])
                guard let watts = power.watts else {
                    XCTAssertTrue(power.isUpdating, "\(label) t=\(time)")
                    XCTAssertLessThan(time, 12, "\(label): a value within the first windows")
                    continue
                }
                XCTAssertNotEqual(watts, 0, "\(label) t=\(time)")
                XCTAssertEqual(watts, Self.cpuWatts, accuracy: Self.cpuWatts * 0.3, "\(label) t=\(time)")
                shown += 1
            }
            XCTAssertGreaterThan(shown, 0, label)
        }
    }

    // MARK: - Channels → blocks

    func testM5ProChannelsMapToSuperAndPerformanceClusters() throws {
        let reading = SoCPowerReading.make(channelPowers: powers([
            "CPU Energy": 13.33, "PCPU": 11.42, "MCPU0": 1.05, "MCPU1": 0.85,
            "GPU Energy": 0.44, "GPU0": 0.43, "ANE0": 0, "DRAM0": 1.35, "AMCC0": 1.01, "DCS0": 1.30,
            "DISP0": 0.32, "DISPEXT0": 0.12, "ISP0": 0.02, "AVE0": 0.02, "MSR0": 0.02, "FAB0": 0.74, "AFR0": 0.13,
        ]), performanceLevelNames: ["Super", "Performance"])
        XCTAssertEqual(reading.items.map(\.component), [
            .superCoreCluster, .performanceCoreCluster, .gpu, .neuralEngine, .memory,
            .memoryController, .displayEngine, .media, .fabric,
        ])
        XCTAssertEqual(reading.item(.performanceCoreCluster)?.channelNames, ["MCPU0", "MCPU1"])
        XCTAssertEqual(reading.item(.gpu)?.channelNames, ["GPU Energy"], "GPU0 is not counted twice")
        XCTAssertEqual(reading.item(.neuralEngine)?.power.watts, 0, "legal zero")
        XCTAssertEqual(try XCTUnwrap(reading.item(.memoryController)?.power.watts), 2.31, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(reading.item(.fabric)?.power.watts), 0.87, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(reading.cpu?.watts), 13.33, accuracy: 0.001)
        // The research total of the same phase: 18.8 W (SMC PZC0 18.8 W).
        XCTAssertEqual(try XCTUnwrap(reading.total?.watts), 18.80, accuracy: 0.01)
        XCTAssertTrue(reading.unsupportedComponents.isEmpty)
    }

    func testOtherChipsClusterNames() {
        let m5 = SoCPowerReading.make(
            channelPowers: powers(["PCPU": 3, "ECPU": 1, "GPU Energy": 1]),
            performanceLevelNames: ["Super", "Efficiency"]
        )
        XCTAssertEqual(m5.items.map(\.component), [.superCoreCluster, .efficiencyCoreCluster, .gpu])

        let m1ToM4 = SoCPowerReading.make(
            channelPowers: powers(["PCPU": 3, "ECPU": 1, "GPU Energy": 1]),
            performanceLevelNames: ["Performance", "Efficiency"]
        )
        XCTAssertEqual(m1ToM4.items.map(\.component), [.performanceCoreCluster, .efficiencyCoreCluster, .gpu])
        XCTAssertEqual(m1ToM4.cpu?.watts, 4, "without CPU Energy the clusters are summed")
    }

    func testMissingChannelsAreHiddenAndNamedUnsupported() {
        let reading = SoCPowerReading.make(
            channelPowers: powers(["CPU Energy": 5, "PCPU": 5, "GPU0": 2, "DRAM0": 1]),
            performanceLevelNames: ["Performance"]
        )
        XCTAssertEqual(reading.items.map(\.component), [.performanceCoreCluster, .gpu, .memory])
        XCTAssertEqual(reading.item(.gpu)?.channelNames, ["GPU0"], "GPU0 stands in without GPU Energy")
        XCTAssertEqual(reading.unsupportedComponents, [.neuralEngine, .memoryController, .displayEngine, .media, .fabric])
        XCTAssertEqual(reading.total?.watts, 8)
        XCTAssertEqual(SoCPowerReading.make(channelPowers: [:], performanceLevelNames: []), .unsupported)
    }

    func testPerCoreSRAMAndPCIeChannelsAreNotUsed() {
        for name in ["MCPU0_0", "PACC_3", "PCPU0_SRAM", "MCPU0DTL00", "MCPM0", "PCPM", "PCIe Port 0 Energy", "apciec0 Energy", "GPU SRAM"] {
            XCTAssertNil(SoCEnergyChannelClassifier.role(forChannel: name), name)
        }
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "CPU Energy"), .cpuTotal)
        // Ultra: macmon reads "DIE_{}_CPU Energy"; a space before "CPU" is
        // accepted too (D57 supplement: anything ending in "CPU Energy").
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "DIE_1_CPU Energy"), .cpuTotal)
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "DIE_1 CPU Energy"), .cpuTotal)
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "MCPU1"), .cluster(prefix: "MCPU"))
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "DISPEXT0"), .component(.displayEngine))
    }

    /// M1/M2 Ultra prefix every Energy Model channel with its die. Before
    /// the D57 supplement none of them matched, so the chip total showed the
    /// GPU alone, without the CPU.
    func testUltraDieChannelNamesAreClassifiedAndSummedOverBothDies() throws {
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "DIE_0_PCPU"), .cluster(prefix: "PCPU"))
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "DIE_0_PCPU1"), .cluster(prefix: "PCPU"))
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "DIE_1_ECPU"), .cluster(prefix: "ECPU"))
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "DIE_1_GPU Energy"), .gpuTotal)
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "DIE_0_GPU0"), .gpuCluster)
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "DIE_1_DRAM0"), .component(.memory))
        XCTAssertEqual(SoCEnergyChannelClassifier.role(forChannel: "DIE_12_AMCC3"), .component(.memoryController))
        for name in ["DIE_0_PCPU0_SRAM", "DIE_1_MCPU0_0", "DIE_X_PCPU", "DIE__PCPU", "DIE_0_", "DIE_0PCPU", "XDIE_0_PCPU"] {
            XCTAssertNil(SoCEnergyChannelClassifier.role(forChannel: name), name)
        }

        let reading = SoCPowerReading.make(
            channelPowers: powers([
                "DIE_0_CPU Energy": 9, "DIE_1_CPU Energy": 7,
                "DIE_0_PCPU0": 4, "DIE_0_PCPU1": 4, "DIE_0_ECPU": 1,
                "DIE_1_PCPU0": 3.5, "DIE_1_PCPU1": 3, "DIE_1_ECPU": 0.5,
                "GPU Energy": 12, "DIE_0_ANE0": 0.25, "DIE_0_DRAM0": 2, "DIE_1_DRAM0": 1.5,
                "DIE_0_AMCC0": 0.75, "DIE_0_DISP0": 0.3, "DIE_1_AVE0": 0.1, "DIE_0_FAB0": 0.4,
            ]),
            performanceLevelNames: ["Performance", "Efficiency"]
        )
        XCTAssertEqual(reading.cpu?.watts, 16, "both dies' CPU Energy")
        XCTAssertEqual(reading.items.map(\.component), [
            .performanceCoreCluster, .efficiencyCoreCluster, .gpu, .neuralEngine, .memory,
            .memoryController, .displayEngine, .media, .fabric,
        ])
        XCTAssertEqual(reading.item(.performanceCoreCluster)?.power.watts, 14.5)
        XCTAssertEqual(reading.item(.efficiencyCoreCluster)?.power.watts, 1.5)
        XCTAssertEqual(reading.item(.memory)?.channelNames, ["DIE_0_DRAM0", "DIE_1_DRAM0"])
        XCTAssertEqual(reading.unsupportedComponents, [])
        // 16 + 12 + 0.25 + 3.5 + 0.75 + 0.3 + 0.1 + 0.4: the clusters are
        // inside the CPU and are not added again.
        XCTAssertEqual(try XCTUnwrap(reading.total?.watts), 33.3, accuracy: 0.0001)
    }

    func testWithoutACPUPartThereIsNoChipTotalAndTheCPUIsNamedUnsupported() {
        let reading = SoCPowerReading.make(
            channelPowers: powers(["GPU Energy": 2, "ANE0": 0.5, "DRAM0": 1]),
            performanceLevelNames: ["Performance", "Efficiency"]
        )
        XCTAssertNil(reading.cpu)
        XCTAssertNil(reading.total, "the other blocks alone are not a chip total")
        XCTAssertEqual(reading.items.map(\.component), [.gpu, .neuralEngine, .memory])
        XCTAssertEqual(reading.unsupportedComponents, [.cpu, .memoryController, .displayEngine, .media, .fabric])
        XCTAssertEqual(SoCPowerComponent.cpu.title, "CPU")
    }

    func testTotalWaitsForEveryPartAndCarriesUpdating() {
        var parts = powers(["CPU Energy": 5, "PCPU": 5, "GPU Energy": 1])
        parts["GPU Energy"] = SoCChannelPower(watts: nil, isUpdating: true)
        let first = SoCPowerReading.make(channelPowers: parts, performanceLevelNames: ["Performance"])
        XCTAssertNil(first.total?.watts, "no total from a partial window")
        XCTAssertEqual(first.total?.isUpdating, true)

        parts["GPU Energy"] = SoCChannelPower(watts: 1, isUpdating: true)
        let carried = SoCPowerReading.make(channelPowers: parts, performanceLevelNames: ["Performance"])
        XCTAssertEqual(carried.total?.watts, 6)
        XCTAssertEqual(carried.total?.isUpdating, true)

        parts["GPU Energy"] = SoCChannelPower(watts: nil, isUpdating: false, isInvalid: true)
        XCTAssertEqual(
            SoCPowerReading.make(channelPowers: parts, performanceLevelNames: ["Performance"]).total?.isInvalid,
            true
        )
    }

    func testSamplerWithoutEnergyModelIsUnsupported() {
        let sampler = SoCPowerSampler(performanceLevelNames: ["Super", "Performance"], readerFactory: { nil })
        XCTAssertEqual(sampler.sample(), .unsupported)
    }

    // MARK: - Fixture

    static let cpuWatts = 13.33
    static let gpuWatts = 0.44
    /// Batches every 2.1 s ± 30 ms, as measured (2.09, 2.12, 2.10…).
    private let batchTimes: [Double] = {
        var times: [Double] = []
        var time = 0.05
        var index = 0
        while time < 260 {
            times.append(time)
            time += 2.1 + [0.02, -0.03, 0.01, 0.0, -0.01, 0.03][index % 6]
            index += 1
        }
        return times
    }()

    /// Cumulative counters at `time`: mJ batched, nJ continuous.
    private func counters(at time: Double) -> [SoCEnergyCounter] {
        let lastBatch = batchTimes.last { $0 <= time } ?? 0
        let batchedEnergy = Int64((Self.cpuWatts * lastBatch * 1_000).rounded())
        return [
            SoCEnergyCounter(name: "CPU Energy", unitLabel: "mJ", value: 3_437_434_243 + batchedEnergy, updatedAt: lastBatch),
            SoCEnergyCounter(name: "ANE0", unitLabel: "mJ", value: 1_295_311, updatedAt: lastBatch),
            SoCEnergyCounter(
                name: "GPU Energy", unitLabel: "nJ",
                value: 248_295_858_603_715 + Int64((Self.gpuWatts * time * 1e9).rounded()), updatedAt: time
            ),
        ]
    }

    private func counter(_ name: String, _ millijoules: Int64, at time: Double) -> SoCEnergyCounter {
        SoCEnergyCounter(name: name, unitLabel: "mJ", value: millijoules, updatedAt: time)
    }

    private func powers(_ watts: [String: Double]) -> [String: SoCChannelPower] {
        watts.mapValues { SoCChannelPower(watts: $0, isUpdating: false) }
    }

    private func jitteredTimes(start: Double, until end: Double, range: ClosedRange<Double>) -> [Double] {
        var generator = SoCCadenceJitter(seed: 57)
        var times = [start]
        while let last = times.last, last < end {
            let unit = Double(generator.next() % 10_000) / 10_000
            times.append(last + range.lowerBound + unit * (range.upperBound - range.lowerBound))
        }
        return times
    }
}

/// Deterministic jitter for the cadence fixture.
private struct SoCCadenceJitter {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
