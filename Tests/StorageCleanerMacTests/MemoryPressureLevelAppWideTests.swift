import XCTest
@testable import StorageCleanerMac

/// D28 (2026-10-04): the memory pressure level comes from macOS across the
/// whole app (`kern.memorystatus_vm_pressure_level`, the source Activity
/// Monitor uses): the main window's memory page, the overview, the simple
/// panel, the mini window and optimization results. The percent is only a
/// number. A sample without the system level (an older sample, or one taken
/// while the level could not be read) is estimated by the single percent
/// rule, 85 % elevated and 95 % high. The words are 正常／升高／高.
@MainActor
final class MemoryPressureLevelAppWideTests: XCTestCase {
    func testTheLevelWordsAreNormalElevatedHigh() {
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertEqual(MemoryPressureLevel.normal.title, "正常")
        XCTAssertEqual(MemoryPressureLevel.elevated.title, "升高")
        XCTAssertEqual(MemoryPressureLevel.critical.title, "高")
        chinese.restore()

        let english = MiniWindowLogicLanguageScope(.english)
        defer { english.restore() }
        XCTAssertEqual(MemoryPressureLevel.normal.title, "Normal")
        XCTAssertEqual(MemoryPressureLevel.elevated.title, "Elevated")
        XCTAssertEqual(MemoryPressureLevel.critical.title, "High")
    }

    /// The advice text (main window, simple panel, action messages) reads the
    /// same level the rings show. Before D28 it used the app's own estimate
    /// from available memory, swap and compression.
    func testAdviceFollowsTheSystemLevelOrOnlyThePercentRule() {
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }

        // No system level, 50 % pressure, little available memory: the old
        // estimate said elevated, the percent rule reads normal.
        let estimated = Self.snapshot(level: nil, freePercentage: 50, availableBytes: 1_000_000_000)
        XCTAssertEqual(estimated.reportablePressureLevel, .normal)
        XCTAssertEqual(estimated.cleanupPlan.title, "当前状态正常")

        // The system level wins over the percent, both ways.
        XCTAssertEqual(Self.snapshot(level: .normal, freePercentage: 3).cleanupPlan.title, "当前状态正常")
        XCTAssertEqual(Self.snapshot(level: .critical, freePercentage: 90).cleanupPlan.title, "继续观察压力")
        XCTAssertEqual(Self.snapshot(level: nil, freePercentage: 10).cleanupPlan.title, "继续观察压力",
                       "90 % without a system level is elevated by the percent rule")

        // Neither a level nor a percent: the advice claims neither normal
        // memory nor pressure signals.
        let unknown = Self.snapshot(level: nil, freePercentage: nil)
        XCTAssertNil(unknown.reportablePressureLevel)
        XCTAssertEqual(unknown.cleanupPlan.title, "继续观察")
        XCTAssertFalse(unknown.cleanupPlan.detail.contains("压力信号"))
        XCTAssertTrue(unknown.cleanupPlan.detail.contains("读不到"))
        XCTAssertEqual(unknown.cleanupPlan.primaryAction, .observe)
    }

    func testTheOwnEstimateIsGoneFromTheApp() throws {
        let models = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Models/SystemModels.swift")
        XCTAssertFalse(models.contains("var pressureLevel: MemoryPressureLevel {"),
                       "one level for display and advice: reportablePressureLevel")
        let domain = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Features/Memory/Domain/MemoryDomain.swift")
        XCTAssertFalse(domain.contains("availableRatio <= 0.125"), "the available-memory estimate is removed")
        XCTAssertTrue(domain.contains("let pressureBefore: MemoryPressureLevel?"),
                      "an optimization result records an unknown level as unknown")

        // The mini window's optimization result shows the same level.
        let memory = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        XCTAssertFalse(memory.contains(".pressureLevel.title"))
        XCTAssertTrue(memory.contains("result.beforeSnapshot.reportablePressureLevel?.title"))
        XCTAssertTrue(memory.contains("result.snapshot.reportablePressureLevel?.title"))

        // The main window's ring help names the system level.
        let utilities = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        XCTAssertFalse(utilities.contains("环颜色表示评估等级"))
        XCTAssertTrue(utilities.contains("环颜色表示 macOS 报告的内存压力等级"))
    }

    // MARK: - Helpers

    /// A 16 GB Mac with 4 GB available unless stated.
    static func snapshot(
        level: MemoryPressureLevel?,
        freePercentage: Int?,
        availableBytes: Int64 = 4_000_000_000
    ) -> MemorySnapshot {
        let physical: Int64 = 16_000_000_000
        let measurements = MemoryMeasurements(
            pressure: level.map { .available($0) }
                ?? .unavailable(.unsupported, reason: "The system level could not be read."),
            physicalBytes: .available(UInt64(physical)),
            availableBytes: .available(UInt64(availableBytes)),
            appBytes: .available(6_000_000_000),
            wiredBytes: .available(2_000_000_000),
            compressedBytes: .available(4_000_000_000),
            cachedBytes: .available(500_000_000),
            swapUsedBytes: .available(5_000_000_000),
            swapInRate: .unavailable(.temporarilyInvalid, reason: "Not needed"),
            swapOutRate: .unavailable(.temporarilyInvalid, reason: "Not needed")
        )
        return MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: physical,
            freeBytes: availableBytes,
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: 0,
            purgeableBytes: 0,
            wiredBytes: 2_000_000_000,
            compressedBytes: 4_000_000_000,
            swapUsedBytes: 5_000_000_000,
            pressureFreePercentage: freePercentage,
            pressureSummary: "test",
            topProcesses: [],
            measurements: measurements
        )
    }
}
