import XCTest
@testable import StorageCleanerMac

final class FeatureLightfieldComponentGeometryTests: XCTestCase {
    func testRingSquareCornersStayInsideInnerCircleAtAllDiameters() {
        for diameter in [CGFloat(1), 32, 48, 64, 76, 96, 132, 180, 300] {
            let geometry = LightfieldRingGeometry(diameter: diameter)
            let cornerRadius = hypot(geometry.textBounds.width / 2, geometry.textBounds.height / 2)
            XCTAssertLessThanOrEqual(cornerRadius, diameter / 2 - geometry.stroke + 0.001)
            XCTAssertEqual(geometry.textBounds.midX, diameter / 2, accuracy: 0.001)
            XCTAssertEqual(geometry.textBounds.midY, diameter / 2, accuracy: 0.001)
        }
        XCTAssertEqual(LightfieldRingGeometry(diameter: .nan).diameter, 1)
    }
    func testProgressClampsAndUnknownIsNeverAZeroMeasurement() {
        XCTAssertNil(LightfieldChartGeometry.fraction(nil))
        XCTAssertNil(LightfieldChartGeometry.fraction(.nan))
        XCTAssertNil(LightfieldChartGeometry.fraction(.infinity))
        XCTAssertEqual(LightfieldChartGeometry.fraction(-0.5), 0)
        XCTAssertEqual(LightfieldChartGeometry.fraction(1.5), 1)
        XCTAssertEqual(LightfieldChartGeometry.segment(index: 7, count: 18, progress: 0.42), .current)
        XCTAssertEqual(LightfieldChartGeometry.segment(index: 6, count: 18, progress: 0.42), .complete)
        XCTAssertEqual(LightfieldChartGeometry.segment(index: 8, count: 18, progress: 0.42), .pending)
        XCTAssertEqual(LightfieldChartGeometry.segment(index: 0, count: 18, progress: nil), .pending)
        XCTAssertEqual(LightfieldChartGeometry.segment(index: 17, count: 18, progress: 1), .complete)
        XCTAssertEqual(LightfieldChartGeometry.segment(index: 0, count: 18, progress: 0), .current)
    }
    /// Review P2-4: one breathing cell at most; none when done/unknown.
    func testSegmentedProgressBreathesOnlyTheCurrentCell() {
        XCTAssertEqual(LightfieldChartGeometry.breathingSegments(count: 18, progress: 0.42), [7])
        XCTAssertEqual(LightfieldChartGeometry.breathingSegments(count: 18, progress: 0), [0])
        XCTAssertEqual(LightfieldChartGeometry.breathingSegments(count: 18, progress: 1), [])
        XCTAssertEqual(LightfieldChartGeometry.breathingSegments(count: 18, progress: nil), [])
        XCTAssertEqual(LightfieldChartGeometry.breathingSegments(count: 0, progress: 0.5), [])
    }
    func testTrendHoverIndexEndpointsAndCoordinates() {
        XCTAssertEqual(LightfieldChartGeometry.index(at: -2, width: 100, count: 5), 0)
        XCTAssertEqual(LightfieldChartGeometry.index(at: 35, width: 100, count: 5), 1)
        XCTAssertEqual(LightfieldChartGeometry.index(at: 49, width: 100, count: 5), 2)
        XCTAssertEqual(LightfieldChartGeometry.index(at: 103, width: 100, count: 5), 4)
        XCTAssertEqual(LightfieldChartGeometry.index(at: 50, width: 100, count: 1), 0)
        XCTAssertNil(LightfieldChartGeometry.index(at: 50, width: 0, count: 5))
        XCTAssertNil(LightfieldChartGeometry.index(at: 50, width: 100, count: 0))
        XCTAssertEqual(LightfieldChartGeometry.point(index: 0, count: 5, value: 1, size: .init(width: 100, height: 50)), .zero)
        XCTAssertEqual(LightfieldChartGeometry.point(index: 4, count: 5, value: 0, size: .init(width: 100, height: 50)), .init(x: 100, y: 50))
    }
    /// Review P1: a click (press without a 3 pt drag) must never create a
    /// one-sample range; the view clears an existing range on such a release.
    func testTrendClickBelowDragThresholdNeverCreatesARange() throws {
        let samples = (0..<5).map { LightfieldTrendSample(time: Date(timeIntervalSince1970: Double($0)), value: 0.5) }
        XCTAssertEqual(LightfieldChartGeometry.minimumDragDistance, 3)
        XCTAssertNil(LightfieldChartGeometry.dragSelection(startX: 50, currentX: 50, width: 100, samples: samples))
        XCTAssertNil(LightfieldChartGeometry.dragSelection(startX: 50, currentX: 52.9, width: 100, samples: samples))
        XCTAssertNil(LightfieldChartGeometry.dragSelection(startX: 50, currentX: 47.1, width: 100, samples: samples))
        XCTAssertEqual(try XCTUnwrap(LightfieldChartGeometry.dragSelection(startX: 50, currentX: 100, width: 100, samples: samples)).range, 2...4)
        XCTAssertEqual(try XCTUnwrap(LightfieldChartGeometry.dragSelection(startX: 50, currentX: 0, width: 100, samples: samples)).range, 0...2)
        XCTAssertNil(LightfieldChartGeometry.dragSelection(startX: 0, currentX: 80, width: 100, samples: []))
    }
    /// Review P2-1: a live refresh (oldest dropped, newest appended) keeps the
    /// hovered moment and the range by timestamp, at their new indices.
    func testTrendHoverAndRangeStayAnchoredToTimestampsAcrossRefresh() throws {
        let old = (0..<6).map { LightfieldTrendSample(time: Date(timeIntervalSince1970: Double($0) * 5), value: Double($0) / 10) }
        let new = Array(old.dropFirst(2)) + (6..<8).map { LightfieldTrendSample(time: Date(timeIntervalSince1970: Double($0) * 5), value: 0.9) }
        XCTAssertEqual(LightfieldChartGeometry.anchoredIndex(time: old[3].time, in: old), 3)
        XCTAssertEqual(LightfieldChartGeometry.anchoredIndex(time: old[3].time, in: new), 1)
        XCTAssertNil(LightfieldChartGeometry.anchoredIndex(time: old[1].time, in: new), "Scrolled out of the window")
        XCTAssertNil(LightfieldChartGeometry.anchoredIndex(time: nil, in: new))
        let kept = try XCTUnwrap(LightfieldChartGeometry.anchoredSelection(times: old[2].time...old[4].time, in: new))
        XCTAssertEqual(kept.range, 0...2)
        XCTAssertEqual(try XCTUnwrap(kept.average), 0.3, accuracy: 1e-12)
        let clamped = try XCTUnwrap(LightfieldChartGeometry.anchoredSelection(times: old[0].time...old[3].time, in: new))
        XCTAssertEqual(clamped.range, 0...1, "Oldest end scrolled out: clamp to the first sample")
        XCTAssertNil(LightfieldChartGeometry.anchoredSelection(times: old[0].time...old[1].time, in: new))
        XCTAssertNil(LightfieldChartGeometry.anchoredSelection(times: nil, in: new))
    }
    /// An interior timestamp bound must exclude older samples both before
    /// and after a live refresh, including bounds between sample timestamps.
    func testTrendSelectionExcludesSamplesBeforeTimestampLowerBoundAcrossRefresh() throws {
        let old = (0..<6).map { LightfieldTrendSample(time: Date(timeIntervalSince1970: Double($0) * 5), value: Double($0) / 10) }
        let new = Array(old.dropFirst(2)) + (6..<8).map { LightfieldTrendSample(time: Date(timeIntervalSince1970: Double($0) * 5), value: 0.9) }
        let times = old[3].time...old[4].time
        let original = try XCTUnwrap(LightfieldChartGeometry.anchoredSelection(times: times, in: old))
        XCTAssertEqual(original.range, 3...4)
        XCTAssertEqual(original.measuredCount, 2)
        XCTAssertEqual(try XCTUnwrap(original.average), 0.35, accuracy: 1e-12)
        let refreshed = try XCTUnwrap(LightfieldChartGeometry.anchoredSelection(times: times, in: new))
        XCTAssertEqual(refreshed.range, 1...2, "Older retained samples are outside the selected timestamps")
        XCTAssertEqual(refreshed.measuredCount, 2)
        XCTAssertEqual(try XCTUnwrap(refreshed.average), 0.35, accuracy: 1e-12)
        let between = try XCTUnwrap(LightfieldChartGeometry.anchoredSelection(
            times: old[3].time.addingTimeInterval(1)...old[4].time, in: new))
        XCTAssertEqual(between.range, 2...2, "A lower bound between samples starts at the next timestamp")
        XCTAssertEqual(between.measuredCount, 1)
        XCTAssertEqual(try XCTUnwrap(between.average), 0.4, accuracy: 1e-12)
    }
    func testTrendValueFormatsKeepPercentDefaultAndAddUnits() {
        XCTAssertEqual(LightfieldTrendValueFormat.percent.compact(0.581), "58.1%")
        XCTAssertEqual(LightfieldTrendValueFormat.percent.detail(0.581), "58.1%")
        let memory = LightfieldTrendValueFormat.scaledWithPercent(maximum: 32, unit: "GB")
        XCTAssertEqual(memory.compact(0.58125), "58.1%")
        XCTAssertEqual(memory.detail(0.58125), "18.6 GB · 58.1%")
        let temperature = LightfieldTrendValueFormat.scaled(maximum: 100, unit: "°C", fractionDigits: 0)
        XCTAssertEqual(temperature.compact(0.53), "53 °C")
        XCTAssertEqual(temperature.detail(nil), L10n.text("未提供", "Unavailable"))
    }
    func testTrendReverseDragAverageExcludesMissingMeasurements() throws {
        let samples = [0.2, nil, 0.4, Double.nan, 0.8].enumerated().map { index, value in
            LightfieldTrendSample(time: Date(timeIntervalSince1970: Double(index)), value: value)
        }
        let selection = try XCTUnwrap(LightfieldChartGeometry.selection(start: 4, end: 0, samples: samples))
        XCTAssertEqual(selection.range, 0...4)
        XCTAssertEqual(selection.measuredCount, 3)
        XCTAssertEqual(try XCTUnwrap(selection.average), 1.4 / 3, accuracy: 1e-12)
        let missing = try XCTUnwrap(LightfieldChartGeometry.selection(start: 1, end: 1, samples: samples))
        XCTAssertNil(missing.average)
        XCTAssertEqual(missing.measuredCount, 0)
        XCTAssertNil(LightfieldChartGeometry.selection(start: 0, end: 0, samples: []))
    }
    func testBubblePackingIsDeterministicCenteredAreaProportionalAndNonoverlapping() throws {
        let inputs: [[(id: String, value: Double)]] = [
            [("a", 20), ("b", 10), ("c", 5), ("d", 1)],
            (0..<30).map { (String(format: "%02d", $0), 1) },
            (0..<45).map { (String($0), pow(0.75, Double($0))) }]
        for values in inputs {
            for size in [CGSize(width: 216, height: 216), .init(width: 500, height: 260), .init(width: 80, height: 60)] {
                let placements = LightfieldBubbleLayout.placements(values: values, size: size)
                XCTAssertEqual(placements, LightfieldBubbleLayout.placements(values: Array(values.reversed()), size: size))
                // Review P2-3: beyond 24 the tail merges into one "other" bubble.
                XCTAssertEqual(placements.count, min(values.count, LightfieldBubbleLayout.maximumBubbles))
                let merged = LightfieldBubbleLayout.merged(values)
                let first = try XCTUnwrap(placements.first)
                XCTAssertEqual(first.center, .init(x: size.width / 2, y: size.height / 2))
                let largestValue = try XCTUnwrap(merged.values.first { $0.id == first.id }).value
                XCTAssertEqual(largestValue, merged.values.map(\.value).max(), "The largest displayed bubble stays centered")
                // Either every bubble meets the 14 pt minimum, or (a field too
                // small for it) the layout keeps exact area ratios throughout.
                let meetsMinimum = placements.allSatisfy { $0.radius >= LightfieldBubbleLayout.minimumRadius - 0.01 }
                if size.width >= 216 { XCTAssertTrue(meetsMinimum, "\(size) holds the approved 14 pt minimum") }
                let floor = placements.map(\.radius).min() ?? 0
                for (index, placement) in placements.enumerated() {
                    let value = try XCTUnwrap(merged.values.first { $0.id == placement.id }).value
                    // Area ratios hold for every bubble above the raised floor;
                    // a bubble on the floor would have been no larger.
                    if !meetsMinimum || placement.radius > floor + 0.01 {
                        XCTAssertEqual(pow(placement.radius / first.radius, 2), value / largestValue, accuracy: 1e-9, "\(size)")
                    } else {
                        XCTAssertLessThanOrEqual(value / largestValue, pow(floor / first.radius, 2) + 1e-9, "\(size)")
                    }
                    let envelope = placement.frame.insetBy(dx: -placement.radius * 0.04, dy: -placement.radius * 0.04)
                    XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.001, dy: -0.001).contains(envelope))
                    for other in placements.dropFirst(index + 1) {
                        XCTAssertGreaterThanOrEqual(hypot(placement.center.x - other.center.x, placement.center.y - other.center.y) + 0.001,
                            (placement.radius + other.radius) * 1.04)
                    }
                }
            }
        }
        XCTAssertEqual(LightfieldBubbleLayout.hoverScale, 1.04)
        // D193③: the user lowered the threshold to about 80 pt (was 100).
        XCTAssertEqual(LightfieldBubbleLayout.labelThreshold, 80)
    }
    /// Main-session visual round: values copied from the approved mockups'
    /// module table (renders/a performance-running, energy, startup, updater;
    /// renders/b files). Without them these modules fell back to legacy themes.
    func testApprovedMockupAccentTokensCoverTheB3ToB7Modules() {
        // D154: these modules now take their CleanMyMac module's colours
        // (were the B3–B7 mockup values: pink for startup, energy and the
        // benchmark, violet for updates, teal for the file tools).
        for (module, family) in [(ReviewFilter.startup, CareStudioFamily.performance), (.energy, .myTools),
            (.performance, .myTools), (.updater, .applications),
            (.largeFiles, .spaceMap), (.migration, .myTools)] {
            XCTAssertEqual(FeatureLightfieldPalette.accents(module), family.palette.action, module.rawValue)
        }
    }
    func testBubbleTailMergesBeyondTwentyFourAndKeepsTheTotal() throws {
        let values = (0..<30).map { (id: String(format: "%02d", $0), value: Double(30 - $0)) }
        let merged = LightfieldBubbleLayout.merged(values)
        XCTAssertEqual(merged.values.count, 24)
        XCTAssertEqual(merged.values.last?.id, LightfieldBubbleLayout.otherID)
        XCTAssertEqual(merged.mergedIDs, (23..<30).map { String(format: "%02d", $0) })
        XCTAssertEqual(try XCTUnwrap(merged.values.last).value, (1...7).reduce(0) { $0 + Double($1) })
        XCTAssertEqual(LightfieldBubbleLayout.merged(Array(values.prefix(24))).mergedIDs, [])
        let placements = LightfieldBubbleLayout.placements(values: values, size: .init(width: 510, height: 268))
        XCTAssertEqual(placements.count, 24)
        XCTAssertTrue(placements.contains { $0.id == LightfieldBubbleLayout.otherID })
    }
    func testMergedTailCanBeTheLargestCenteredBubbleWithoutBreakingTheMinimumRadius() throws {
        let values = (0..<30).map { (id: String(format: "%02d", $0), value: 1.0) }
        let size = CGSize(width: 216, height: 216)
        let placements = LightfieldBubbleLayout.placements(values: values, size: size)
        let first = try XCTUnwrap(placements.first)
        XCTAssertEqual(first.id, LightfieldBubbleLayout.otherID)
        XCTAssertEqual(first.center, CGPoint(x: 108, y: 108))
        XCTAssertEqual(placements.count, 24)
        XCTAssertTrue(placements.allSatisfy { $0.radius >= 14 - 0.01 })
    }
    /// Review P2-3: values + size are the cache key; hover never re-packs.
    @MainActor func testBubbleLayoutIsCachedByValuesAndSize() {
        let cache = LightfieldBubbleLayoutCache()
        let values: [(id: String, value: Double)] = [("a", 20), ("b", 10), ("c", 5)]
        let size = CGSize(width: 510, height: 268)
        let first = cache.placements(values: values, size: size)
        for _ in 0..<5 { XCTAssertEqual(cache.placements(values: values, size: size), first) }
        XCTAssertEqual(cache.computeCount, 1)
        _ = cache.placements(values: values, size: .init(width: 400, height: 268))
        _ = cache.placements(values: [("a", 20), ("b", 11), ("c", 5)], size: .init(width: 400, height: 268))
        XCTAssertEqual(cache.computeCount, 3)
    }
    /// Review P2-7: a 32 pt bubble icon at 2x needs 64 px, so it loads 84 px.
    func testOptionIconVariantFollowsDrawnPixelSize() {
        XCTAssertEqual(LightfieldOptionIcon.variant(pointSize: 32, displayScale: 2), .threeX)
        XCTAssertEqual(LightfieldOptionIcon.variant(pointSize: 28, displayScale: 2), .twoX)
        XCTAssertEqual(LightfieldOptionIcon.variant(pointSize: 24, displayScale: 2), .twoX)
        XCTAssertEqual(LightfieldOptionIcon.variant(pointSize: 28, displayScale: 3), .threeX)
        XCTAssertEqual(LightfieldOptionIcon.variant(pointSize: 14, displayScale: 1), .twoX)
    }
    func testBubbleRejectsInvalidMeasurementsWithoutInventingPositiveArea() {
        XCTAssertTrue(LightfieldBubbleLayout.placements(values: [("nil", .nan), ("zero", 0), ("negative", -1)], size: .init(width: 200, height: 200)).isEmpty)
        XCTAssertTrue(LightfieldBubbleLayout.placements(values: [("a", 1)], size: .zero).isEmpty)
        XCTAssertEqual(LightfieldBubbleLayout.placements(values: [("a", 1), ("a", 1)], size: .init(width: 200, height: 200)).count, 1)
    }
    func testDonutHas132DiameterAndSharesSumToOneEvenForHugeInputs() {
        let arcs = LightfieldDonutGeometry.arcs(values: [("a", 20), ("b", 10), ("c", 5), ("zero", 0)])
        XCTAssertEqual(arcs.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(arcs.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-12)
        XCTAssertEqual(arcs[0].fraction, 20 / 35, accuracy: 1e-12)
        XCTAssertEqual(LightfieldDonutGeometry.diameter, 132)
        let huge = LightfieldDonutGeometry.arcs(values: [("a", Double.greatestFiniteMagnitude), ("b", Double.greatestFiniteMagnitude)])
        XCTAssertEqual(huge.map(\.fraction), [0.5, 0.5])
        XCTAssertTrue(LightfieldDonutGeometry.arcs(values: [("x", .nan)]).isEmpty)
    }
}
