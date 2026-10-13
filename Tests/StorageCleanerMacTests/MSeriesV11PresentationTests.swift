import Foundation
import XCTest
@testable import StorageCleanerMac

final class MSeriesV11PresentationTests: XCTestCase {
    func testOptionalAcceleratorStageHasAChineseTitle() {
        XCTAssertEqual(MSeriesRunItemTitles.chineseTitle(for: "accelerators"), "独立加速单元")
    }

    func testAllCoreAndExtensionIDsHaveChineseNamesAndDynamicNumbersAreValidated() {
        let ids = MSeriesProtocol.coreIDs + ["power.cpu.single","power.cpu.performanceCores","power.cpu.allCores",
            "power.gpu.peak","sustained.cpu.allCores","sustained.gpu","pressure.cpu.allCores","pressure.gpu",
            "media.h264.encode","media.h264.decode","media.hevc.encode","media.hevc.decode","media.prores.encode",
            "media.prores.decode","media.av1.decode","gpu.hardwareRayTracing.build","gpu.hardwareRayTracing.traversal",
            "gpu.tensor.fp16","ai.smallModel.cpu","ai.smallModel.aneCandidate","ai.smallModel.accelerationRatio",
            "preflight","finalizing","cancelling"]
        for id in ids { XCTAssertNotEqual(MSeriesRunItemTitles.chineseTitle(for: id), "扩展测试 · 名称待适配", id) }
        XCTAssertEqual(MSeriesRunItemTitles.chineseTitle(for: "cpu.multi.compression"), "CPU 多线程 · 压缩")
        XCTAssertEqual(MSeriesRunItemTitles.chineseTitle(for: "cpu.threadCurve.18"), "CPU 线程曲线 · 18 线程")
        XCTAssertEqual(MSeriesRunItemTitles.chineseTitle(for: "cpu.sustained.short.12"), "CPU 短持续观察 · 第 12 批")
        for id in ["cpu.threadCurve.0","cpu.threadCurve.-1","cpu.threadCurve.nope","cpu.sustained.short.0","future.unit"] {
            XCTAssertEqual(MSeriesRunItemTitles.chineseTitle(for: id), "扩展测试 · 名称待适配")
        }
    }
    func testStandardProgressUses460WeightsAndCapsAt99UntilAtomicSaveSuccess() throws {
        XCTAssertEqual(MSeriesStageBudget.standardV11.map(\.weight), [5,180,45,35,95,95,5])
        var tracker = try MSeriesStageProgress(budgets: MSeriesStageBudget.standardV11, nowNanoseconds: 0)
        XCTAssertEqual(tracker.fraction(nowNanoseconds: 2_500_000_000), 2.5/460, accuracy: 1e-12)
        try tracker.advance(to: "core", nowNanoseconds: 5_000_000_000)
        XCTAssertEqual(tracker.fraction(nowNanoseconds: 95_000_000_000), (5+90)/460, accuracy: 1e-12)
        XCTAssertEqual(tracker.fraction(nowNanoseconds: 185_000_000_000), 185/460, accuracy: 1e-12)
        XCTAssertLessThan(tracker.fraction(nowNanoseconds: 999_000_000_000), 1)
        try tracker.advance(to: "cpuEfficiency", nowNanoseconds: 185_000_000_000)
        XCTAssertEqual(tracker.fraction(nowNanoseconds: 200_000_000_000), 200/460, accuracy: 1e-12)
        try tracker.advance(to: "saving", nowNanoseconds: 455_000_000_000)
        XCTAssertEqual(tracker.fraction(nowNanoseconds: 500_000_000_000), 0.99)
        try tracker.didSave()
        XCTAssertEqual(tracker.fraction(nowNanoseconds: 500_000_000_000), 1)
        XCTAssertEqual(tracker.elapsedSeconds(nowNanoseconds: 68_000_000_000), 68)
    }
    func testCancelledProgressFreezesAndOptionalBudgetsStayFrozen() throws {
        let extra = MSeriesStageBudget(id: "accelerator", plannedSeconds: 30, weight: 30)
        let budgets = Array(MSeriesStageBudget.standardV11.dropLast()) + [extra, MSeriesStageBudget.standardV11.last!]
        var tracker = try MSeriesStageProgress(budgets: budgets, nowNanoseconds: 0)
        XCTAssertEqual(tracker.frozenBudgets.reduce(0) { $0 + $1.weight }, 490)
        try tracker.advance(to: "core", nowNanoseconds: 5_000_000_000)
        let fraction = tracker.fraction(nowNanoseconds: 50_000_000_000)
        tracker.stop(nowNanoseconds: 50_000_000_000)
        XCTAssertEqual(tracker.fraction(nowNanoseconds: 500_000_000_000), fraction)
        XCTAssertThrowsError(try tracker.didSave())
        XCTAssertThrowsError(try tracker.advance(to: "saving", nowNanoseconds: 500_000_000_000))
        XCTAssertEqual(MSeriesStageBudget.pressure10m.filter { $0.id.contains("Pressure") }.reduce(0) { $0+$1.weight }, 600)
        XCTAssertThrowsError(try MSeriesStageProgress(budgets: [.init(id: "bad", plannedSeconds: 0, weight: 1)], nowNanoseconds: 0))
    }
}
