import XCTest
@testable import StorageCleanerMac

final class GeekProcessorCorePresentationTests: XCTestCase {
    func testEveryNativeLevelKeepsItsCoreSliceAverageAndLegendColor() throws {
        for coreCount in [18, 27, 32] {
            for levelCount in 1...4 {
                let counts = (0..<levelCount).map { index in
                    coreCount / levelCount + (index < coreCount % levelCount ? 1 : 0)
                }
                let levels = counts.enumerated().map { index, count in
                    CPUPerformanceStateService.PerformanceLevel(
                        index: index, name: "Native Tier \(index + 1)",
                        coreCount: count, coresPerL2: nil
                    )
                }
                // Distinct values make a dropped or misaligned core slice observable.
                let samples = (1...coreCount).map(Double.init)
                let groups = GeekProcessorCorePresentation.groups(
                    levels: levels.reversed(), usageValues: samples,
                    logicalCoreCount: coreCount
                )

                XCTAssertEqual(groups.count, levelCount)
                XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, coreCount)
                XCTAssertEqual(Set(groups.map(\.id)).count, levelCount)
                XCTAssertEqual(Set(groups.compactMap { $0.colorRole?.rawValue }).count, levelCount)
                var coveredOffset = 0
                for (index, group) in groups.enumerated() {
                    XCTAssertEqual(group.levelName, "Native Tier \(index + 1)")
                    XCTAssertEqual(group.count, counts[index])
                    XCTAssertEqual(group.sourceOffset, coveredOffset)
                    let firstValue = Double(coveredOffset + 1)
                    let lastValue = Double(coveredOffset + counts[index])
                    XCTAssertEqual(try XCTUnwrap(group.averageUsagePercent), (firstValue + lastValue) / 2)
                    coveredOffset += counts[index]
                }
                XCTAssertEqual(coveredOffset, coreCount)
            }
        }
    }

    func testCurrentTwoLevelEighteenCorePresentationKeepsItsLayoutAndColors() {
        let groups = GeekProcessorCorePresentation.groups(
            levels: [
                .init(index: 0, name: "Super", coreCount: 6, coresPerL2: 6),
                .init(index: 1, name: "Performance", coreCount: 12, coresPerL2: 6),
            ],
            usageValues: Array(repeating: 80, count: 6) + Array(repeating: 20, count: 12),
            logicalCoreCount: 18
        )

        XCTAssertEqual(groups.map(\.levelName), ["Performance", "Super"])
        XCTAssertEqual(groups.map(\.sourceOffset), [6, 0])
        XCTAssertEqual(groups.map(\.averageUsagePercent), [20, 80])
        XCTAssertEqual(groups.map(\.colorRole), [.secondary, .primary])
        // D119 (2026-10-18): iStat's cores section, 12 rings a row on the
        // 272 pt CPU page: two rows and two legend rows. Was 102 (nine
        // 28 pt rings a row).
        XCTAssertEqual(GeekProcessorCoreLayout.cardHeight(for: 18, groupCount: groups.count), 90)
    }

    func testCardBudgetAccommodatesEveryLegendWithoutShrinkingCoreRings() {
        // D119 (2026-10-18): legend top 10 + 24 × rows − 2, 15 pt per
        // legend row, 4 pt below. Was 18: [102, 102, 116, 130],
        // 27: [119, 133, 147, 161], 32: [150, 164, 178, 192].
        let expectedHeights: [Int: [CGFloat]] = [
            18: [75, 90, 105, 120],
            27: [99, 114, 129, 144],
            32: [99, 114, 129, 144],
        ]
        for (coreCount, heights) in expectedHeights {
            for levelCount in 1...4 {
                let height = GeekProcessorCoreLayout.cardHeight(for: coreCount, groupCount: levelCount)
                XCTAssertEqual(height, heights[levelCount - 1])
                let gridHeight = CGFloat(GeekProcessorCoreLayout.rowCount(for: coreCount))
                    * GeekProcessorCoreLayout.rowPitch
                let legendsHeight = CGFloat(levelCount) * GeekProcessorCoreLayout.legendRowHeight
                XCTAssertGreaterThanOrEqual(height - gridHeight, legendsHeight + 12)
            }
        }
        // D119 (2026-10-18): iStat's 18 pt core rings with a 3 pt line and no
        // number inside (the value is in the ring's help and VoiceOver
        // value). Was a 28 pt ring with an 8 pt number.
        XCTAssertEqual(GeekProcessorCoreLayout.ringSize, 18)
        XCTAssertEqual(GeekProcessorCoreLayout.lineWidth, 3)
        XCTAssertEqual(GeekProcessorCoreLayout.rowPitch, 24)
    }

    func testMissingSamplesRemainUnknownInsteadOfBorrowingAnotherLevelOrShowingZero() {
        let groups = GeekProcessorCorePresentation.groups(
            levels: (0..<3).map {
                .init(index: $0, name: "Tier \($0)", coreCount: 6, coresPerL2: nil)
            },
            usageValues: [10, 20, .nan, .infinity, 30, 40, 90],
            logicalCoreCount: 18
        )

        XCTAssertEqual(groups.map(\.count), [6, 6, 6])
        XCTAssertEqual(groups.map(\.averageUsagePercent), [25, 90, nil])
        XCTAssertEqual(groups.map(\.sourceOffset), [0, 6, 12])
    }

    func testUnavailableNativeLevelsUseTheActualLogicalCoreCountAndFiniteReadings() {
        let groups = GeekProcessorCorePresentation.groups(
            levels: [], usageValues: [.nan, .infinity, 0, 50], logicalCoreCount: 32
        )

        XCTAssertEqual(groups, [.init(
            id: "logical", levelName: nil, count: 32, sourceOffset: 0,
            averageUsagePercent: 25, colorRole: nil
        )])
        let unknown = GeekProcessorCorePresentation.groups(
            levels: [], usageValues: [.nan], logicalCoreCount: 18
        )
        XCTAssertNil(unknown.first?.averageUsagePercent)
        XCTAssertEqual(unknown.first?.count, 18)
    }

    func testFutureAdditionalLevelsAreNotDroppedWhenThePaletteRepeats() {
        let groups = GeekProcessorCorePresentation.groups(
            levels: (0..<5).map {
                .init(index: $0, name: "Future Tier \($0)", coreCount: 4, coresPerL2: nil)
            },
            usageValues: Array(repeating: 30, count: 20), logicalCoreCount: 20
        )

        XCTAssertEqual(groups.count, 5)
        XCTAssertEqual(groups.map(\.averageUsagePercent), Array(repeating: 30, count: 5))
        XCTAssertTrue(groups.allSatisfy { $0.colorRole != nil })
        XCTAssertEqual(groups.last?.sourceOffset, 16)
        // D119 (2026-10-18): two ring rows and five legend rows; was 175.
        XCTAssertEqual(GeekProcessorCoreLayout.cardHeight(for: 20, groupCount: 5), 135)
    }
}
