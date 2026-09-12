import AppKit
import XCTest
@testable import StorageCleanerMac

final class MenuBarPanelPlacementTests: XCTestCase {
    func testLegacyDensityRawValuesAndStoredPreferencesRemainCompatible() throws {
        XCTAssertEqual(PanelDensity.simple.rawValue, "compact")
        XCTAssertEqual(PanelDensity.complex.rawValue, "advanced")
        XCTAssertEqual(PanelDensity.geek.rawValue, "geek")
        XCTAssertEqual(PanelDensity(rawValue: "compact"), .simple)
        XCTAssertEqual(PanelDensity(rawValue: "advanced"), .complex)
        XCTAssertEqual(PanelDensity(rawValue: "geek"), .geek)
        XCTAssertFalse(PanelDensity.simple.usesAttachedDetailPresentation)
        XCTAssertTrue(PanelDensity.complex.usesAttachedDetailPresentation)
        XCTAssertTrue(PanelDensity.geek.usesAttachedDetailPresentation)
        XCTAssertEqual(PanelDensity.complex.idealSize, MiniWindowStyleTokens.overviewSize)
        XCTAssertEqual(PanelDensity.geek.idealSize, MiniWindowStyleTokens.overviewSize)
        XCTAssertEqual(PanelDensity.complex.idealSize, PanelDensity.geek.idealSize)
        XCTAssertEqual(PanelDensity.complex.minimumSize, PanelDensity.complex.idealSize)
        XCTAssertEqual(PanelDensity.geek.minimumSize, PanelDensity.geek.idealSize)

        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        for density in PanelDensity.allCases {
            fixture.defaults.set(density.rawValue, forKey: PanelDensity.defaultsKey)
            XCTAssertEqual(PanelDensity.stored(in: fixture.defaults), .geek)
        }
    }

    func testMiniWindowColumnWidthsUseSharedTokens() {
        XCTAssertEqual(
            GeekPanelPresentationMetrics.overviewSize.width,
            GeekPanelPresentationMetrics.secondaryWidth
        )
        XCTAssertEqual(
            GeekPanelPresentationMetrics.tertiarySize.width,
            MiniWindowStyleTokens.historyWidth
        )

        for density in [PanelDensity.complex, .geek] {
            for section in PanelSection.allCases where section != .overview {
                let expectedWidth = section == .power
                    ? GeekPanelPresentationMetrics.powerDetailWidth
                    : GeekPanelPresentationMetrics.detailWidth
                XCTAssertEqual(
                    GeekPanelPresentationMetrics.detailSize(
                        for: section,
                        density: density
                    ).width,
                    expectedWidth,
                    "Unexpected width for \(density) \(section)"
                )
            }
        }
    }

    func testAnchoredOverviewStaysCenteredAndCascadeUsesAvailableSide() {
        let visible = NSRect(x: 0, y: 0, width: 1_800, height: 900)
        let anchor = NSRect(x: 1_400, y: 900, width: 24, height: 22)
        let overview = MenuBarPanelPlacement.frame(
            anchor: anchor,
            contentSize: MiniWindowStyleTokens.overviewSize,
            visibleFrame: visible
        )
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: overview,
            childSizes: [
                NSSize(width: GeekPanelPresentationMetrics.detailWidth, height: 561),
                MenuBarPanelPlacement.tertiaryMaximumSize,
            ],
            visibleFrame: visible
        )

        XCTAssertEqual(overview.midX, anchor.midX, accuracy: 0.001)
        XCTAssertEqual(layout.direction, .left)
        XCTAssertEqual(layout.tertiaryPresentationMode, .column)
        XCTAssertEqual(layout.childFrames.count, 2)
        assertDisjointAndVisible([overview] + layout.childFrames, visibleFrame: visible)
    }

    func testAnchoredOverviewKeepsItsStatusAlignmentWhenTheScreenCannotFitThreeColumns() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 900)
        let anchor = NSRect(x: 620, y: 900, width: 24, height: 22)
        let overview = MenuBarPanelPlacement.frame(
            anchor: anchor,
            contentSize: MiniWindowStyleTokens.overviewSize,
            visibleFrame: visible
        )

        XCTAssertEqual(overview.midX, anchor.midX, accuracy: 0.001)
    }

    func testAnchoredOverviewClampsAtTheVisibleRightEdgeWithoutChangingWidth() {
        let visible = NSRect(x: 0, y: 0, width: 1_352, height: 900)
        let anchor = NSRect(x: 1_200, y: 900, width: 24, height: 22)
        let overview = MenuBarPanelPlacement.frame(
            anchor: anchor,
            contentSize: MiniWindowStyleTokens.overviewSize,
            visibleFrame: visible
        )

        XCTAssertEqual(overview.maxX, visible.maxX - 8, accuracy: 0.001)
        XCTAssertEqual(overview.width, MiniWindowStyleTokens.overviewSize.width)
    }

    func testThreeColumnCascadeSupportsNegativeExternalDisplayCoordinates() {
        let visible = NSRect(x: -1_920, y: -180, width: 1_920, height: 1_080)
        let anchor = NSRect(x: -420, y: 880, width: 24, height: 22)
        let overview = MenuBarPanelPlacement.frame(
            anchor: anchor,
            contentSize: MiniWindowStyleTokens.overviewSize,
            visibleFrame: visible
        )
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: overview,
            childSizes: [
                NSSize(width: GeekPanelPresentationMetrics.detailWidth, height: 561),
                MenuBarPanelPlacement.tertiaryMaximumSize,
            ],
            visibleFrame: visible
        )

        XCTAssertEqual(layout.direction, .left)
        XCTAssertEqual(layout.tertiaryPresentationMode, .column)
        XCTAssertEqual(layout.childFrames.count, 2)
        assertDisjointAndVisible([overview] + layout.childFrames, visibleFrame: visible)
    }

    func testCascadeBottomAlignsThreeAdjacentLevelsWhenRequested() {
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let parent = NSRect(x: 1_050, y: 100, width: 304, height: 553)
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: parent,
            childSizes: [
                NSSize(width: 312, height: 423),
                NSSize(width: 384, height: 216),
            ],
            visibleFrame: visible,
            preferredAlignment: .bottom,
            childTopOffsets: [0, 386]
        )

        XCTAssertEqual(layout.alignment, .bottom)
        XCTAssertEqual(layout.childFrames.count, 2)
        XCTAssertTrue(layout.visibleFrames.allSatisfy {
            abs($0.minY - parent.minY) < 0.001
        })
        XCTAssertEqual(
            parent.minX - layout.childFrames[0].maxX,
            MiniWindowStyleTokens.cascadeGap,
            accuracy: 0.001
        )
        XCTAssertEqual(
            layout.childFrames[0].minX - layout.childFrames[1].maxX,
            MiniWindowStyleTokens.cascadeGap,
            accuracy: 0.001
        )
        assertDisjointAndVisible(layout.visibleFrames, visibleFrame: visible)
    }

    func testCascadeAnchorAlignsEachChildTopWithItsOwningRow() {
        let visible = NSRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let parent = NSRect(x: 1_100, y: 200, width: 304, height: 553)
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: parent,
            childSizes: [
                NSSize(width: 312, height: 423),
                NSSize(width: 220, height: 180),
            ],
            visibleFrame: visible,
            preferredAlignment: .anchor,
            childTopOffsets: [135, 260]
        )

        XCTAssertEqual(layout.alignment, .anchor)
        XCTAssertEqual(layout.childFrames.count, 2)
        XCTAssertEqual(layout.childFrames[0].maxY, parent.maxY - 135, accuracy: 0.001)
        XCTAssertEqual(layout.childFrames[1].maxY, parent.maxY - 260, accuracy: 0.001)
        assertDisjointAndVisible(layout.visibleFrames, visibleFrame: visible)
    }

    func testCascadeDoesNotReplaceRowAnchoringWithCenterOrBottomAlignment() {
        let visible = NSRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let parent = NSRect(x: 1_100, y: 200, width: 304, height: 553)
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: parent,
            childSizes: [
                NSSize(width: 312, height: 423),
                NSSize(width: 220, height: 180),
            ],
            visibleFrame: visible,
            preferredAlignment: .anchor,
            childTopOffsets: [135, 260]
        )

        XCTAssertEqual(layout.alignment, .anchor)
        XCTAssertEqual(layout.childFrames[0].maxY, parent.maxY - 135, accuracy: 0.001)
        XCTAssertEqual(layout.childFrames[1].maxY, parent.maxY - 260, accuracy: 0.001)
    }

    func testAttachedPanelsKeepGoldenGapAndConsistentRoundedChrome() {
        XCTAssertEqual(MiniWindowStyleTokens.outerCornerRadius, 12)
        XCTAssertEqual(MiniWindowStyleTokens.cardCornerRadius, 10)
        XCTAssertEqual(MiniWindowStyleTokens.anchorGap, 0)
        XCTAssertEqual(MiniWindowStyleTokens.cascadeGap, 0)

        let parent = NSRect(x: 620, y: 200, width: 304, height: 553)
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: parent,
            childSizes: [CGSize(width: 312, height: 400)],
            visibleFrame: visible
        )

        XCTAssertEqual(layout.childFrames.count, 1)
        XCTAssertEqual(parent.minX - layout.childFrames[0].maxX, MiniWindowStyleTokens.cascadeGap)

        let detail = CGRect(x: 0, y: 0, width: 312, height: 561)
        let overview = CGRect(x: 312, y: 0, width: 304, height: 553)
        let detailRadii = GeekAttachedPanelChromeGeometry.cornerRadii(
            for: detail,
            neighbors: [overview],
            radius: MiniWindowStyleTokens.outerCornerRadius
        )
        let overviewRadii = GeekAttachedPanelChromeGeometry.cornerRadii(
            for: overview,
            neighbors: [detail],
            radius: MiniWindowStyleTokens.outerCornerRadius
        )
        XCTAssertEqual(detailRadii.topLeading, MiniWindowStyleTokens.outerCornerRadius)
        XCTAssertEqual(detailRadii.bottomLeading, MiniWindowStyleTokens.outerCornerRadius)
        XCTAssertEqual(detailRadii.bottomTrailing, MiniWindowStyleTokens.outerCornerRadius)
        XCTAssertEqual(detailRadii.topTrailing, MiniWindowStyleTokens.outerCornerRadius)
        XCTAssertEqual(overviewRadii.topLeading, MiniWindowStyleTokens.outerCornerRadius)
        XCTAssertEqual(overviewRadii.bottomLeading, MiniWindowStyleTokens.outerCornerRadius)
        XCTAssertEqual(overviewRadii.bottomTrailing, MiniWindowStyleTokens.outerCornerRadius)
        XCTAssertEqual(overviewRadii.topTrailing, MiniWindowStyleTokens.outerCornerRadius)

        let detailEdges = GeekAttachedPanelChromeGeometry.exposedBorderEdges(
            for: detail,
            neighbors: [overview]
        )
        let overviewEdges = GeekAttachedPanelChromeGeometry.exposedBorderEdges(
            for: overview,
            neighbors: [detail]
        )
        XCTAssertEqual(detailEdges.trailing, [CGFloat.zero ... 1])
        XCTAssertEqual(overviewEdges.leading, [CGFloat.zero ... 1])
    }

    func testPracticalOverviewGroupsFitTheFixedPanelWithoutScrolling() {
        let cards = [
            GeekPanelLayout.overviewProcessorCardHeight,
            GeekPanelLayout.overviewMemoryCardHeight,
            GeekPanelLayout.overviewDiskCardHeight,
            GeekPanelLayout.overviewNetworkCardHeight,
            GeekPanelLayout.overviewSensorsCardHeight,
            GeekPanelLayout.overviewPowerCardHeight,
        ]
        let contentHeight = cards.reduce(0, +)
            + GeekPanelLayout.sectionSpacing * CGFloat(cards.count - 1)
            + GeekPanelLayout.contentPadding * 2
        let computedSize = GeekPanelLayout.overviewSize(showsPowerModule: true)
        XCTAssertEqual(computedSize.height, contentHeight)
        XCTAssertEqual(GeekPanelPresentationMetrics.normalizedOverviewSize(computedSize), computedSize)
        XCTAssertEqual(
            GeekPanelLayout.overviewSize(showsPowerModule: false).height,
            contentHeight - GeekPanelLayout.overviewPowerCardHeight - GeekPanelLayout.sectionSpacing
        )
    }

    func testAttachedPanelChromeKeepsRoundedCornersWhenStacked() {
        let overview = CGRect(x: 0, y: 0, width: 304, height: 553)
        let detail = CGRect(x: 0, y: 553, width: 312, height: 400)

        let overviewRadii = GeekAttachedPanelChromeGeometry.cornerRadii(
            for: overview,
            neighbors: [detail],
            radius: MiniWindowStyleTokens.outerCornerRadius
        )
        let detailRadii = GeekAttachedPanelChromeGeometry.cornerRadii(
            for: detail,
            neighbors: [overview],
            radius: MiniWindowStyleTokens.outerCornerRadius
        )
        XCTAssertEqual(overviewRadii.bottomLeading, MiniWindowStyleTokens.outerCornerRadius)
        XCTAssertEqual(overviewRadii.bottomTrailing, MiniWindowStyleTokens.outerCornerRadius)
        XCTAssertEqual(detailRadii.topLeading, MiniWindowStyleTokens.outerCornerRadius)
        XCTAssertEqual(detailRadii.topTrailing, MiniWindowStyleTokens.outerCornerRadius)

        let overviewEdges = GeekAttachedPanelChromeGeometry.exposedBorderEdges(
            for: overview,
            neighbors: [detail]
        )
        let detailEdges = GeekAttachedPanelChromeGeometry.exposedBorderEdges(
            for: detail,
            neighbors: [overview]
        )
        XCTAssertEqual(overviewEdges.bottom, [CGFloat.zero ... 1])
        XCTAssertEqual(detailEdges.top, [CGFloat.zero ... 1])
    }

    func testAttachedPanelChromeKeepsIndependentTertiaryBorders() {
        let history = CGRect(x: 0, y: 0, width: 368, height: 220)
        let detail = CGRect(x: 368, y: 0, width: 312, height: 561)
        let overview = CGRect(x: 680, y: 0, width: 304, height: 553)

        let detailEdges = GeekAttachedPanelChromeGeometry.exposedBorderEdges(
            for: detail,
            neighbors: [history, overview]
        )
        let overviewEdges = GeekAttachedPanelChromeGeometry.exposedBorderEdges(
            for: overview,
            neighbors: [history, detail]
        )

        XCTAssertEqual(detailEdges.leading, [CGFloat.zero ... 1])
        XCTAssertEqual(detailEdges.trailing, [CGFloat.zero ... 1])
        XCTAssertEqual(overviewEdges.leading, [CGFloat.zero ... 1])
    }

    func testInlineTertiarySizesStayContentDrivenWithinSafeBounds() {
        XCTAssertEqual(
            GeekPanelPresentationMetrics.normalizedTertiarySize(
                CGSize(width: 170, height: 167)
            ),
            CGSize(width: 170, height: 167)
        )
        XCTAssertEqual(
            GeekPanelPresentationMetrics.normalizedTertiarySize(
                CGSize(width: -20, height: 9_000)
            ),
            CGSize(
                width: GeekPanelPresentationMetrics.tertiaryMinimumDimension,
                height: GeekPanelPresentationMetrics.tertiaryMaximumSize.height
            )
        )
        XCTAssertEqual(
            GeekPanelPresentationMetrics.normalizedTertiarySize(
                CGSize(width: CGFloat.nan, height: CGFloat.infinity)
            ),
            GeekPanelPresentationMetrics.tertiarySize
        )
        XCTAssertNil(
            GeekPanelPresentationMetrics.normalizedTertiarySourceOffset(CGFloat.nan)
        )
        XCTAssertEqual(
            GeekPanelPresentationMetrics.normalizedTertiarySourceOffset(-24),
            0
        )
    }

    func testStoredOriginNeverOverridesTheCurrentStatusItemAnchor() throws {
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let visible = NSRect(x: 0, y: 0, width: 1_200, height: 900)
        let legacyFrames: [(PanelDensity, NSRect)] = [
            (.simple, NSRect(x: 10, y: 20, width: 500, height: 330)),
            (.complex, NSRect(x: 30, y: 40, width: 520, height: 680)),
            (.geek, NSRect(x: 50, y: 60, width: 720, height: 680)),
        ]

        for (density, frame) in legacyFrames {
            fixture.store.save(frame: frame, for: density)
            XCTAssertEqual(fixture.store.storedFrame(for: density), frame)
            let anchor = NSRect(x: 600, y: 860, width: 24, height: 20)
            let resolved = fixture.store.resolvedFrame(
                for: density,
                anchor: anchor,
                preferredVisibleFrame: visible,
                availableVisibleFrames: [visible]
            )
            XCTAssertEqual(
                resolved,
                MenuBarPanelPlacement.frame(
                    anchor: anchor,
                    contentSize: density.idealSize,
                    visibleFrame: visible
                )
            )
            XCTAssertEqual(resolved.size, density.idealSize)
        }

        let customFrame = NSRect(x: 70, y: 80, width: 700, height: 560)
        fixture.store.save(frame: customFrame, for: .geek)
        XCTAssertEqual(fixture.store.storedFrame(for: .geek), customFrame)
        let resolvedCustom = fixture.store.resolvedFrame(
            for: .geek,
            anchor: NSRect(x: 600, y: 860, width: 24, height: 20),
            preferredVisibleFrame: visible,
            availableVisibleFrames: [visible]
        )
        XCTAssertNotEqual(resolvedCustom.origin, customFrame.origin)
        XCTAssertEqual(resolvedCustom.midX, 612, accuracy: 0.001)
        XCTAssertEqual(resolvedCustom.size, PanelDensity.geek.idealSize)
    }

    func testGeometryStoreRoundTripsIndependentFramesForAllDensities() throws {
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let expectedFrames: [(PanelDensity, NSRect)] = [
            (.simple, NSRect(x: 20, y: 30, width: 470, height: 320)),
            (.complex, NSRect(x: 80, y: 90, width: 540, height: 620)),
            (.geek, NSRect(x: -820, y: 110, width: 720, height: 560)),
        ]

        for (density, frame) in expectedFrames {
            fixture.store.save(frame: frame, for: density)
        }

        for (density, frame) in expectedFrames {
            XCTAssertEqual(fixture.store.storedFrame(for: density), frame)
        }
    }

    func testGeometryStoreRejectsInvalidFramesWithoutOverwritingValidValue() throws {
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let valid = NSRect(x: 40, y: 50, width: 470, height: 310)
        fixture.store.save(frame: valid, for: .simple)

        let invalidFrames = [
            NSRect(x: 0, y: 0, width: 0, height: 300),
            NSRect(x: 0, y: 0, width: -1, height: 300),
            NSRect(x: CGFloat.nan, y: 0, width: 500, height: 300),
            NSRect(x: 0, y: CGFloat.infinity, width: 500, height: 300),
            NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 300),
        ]
        for frame in invalidFrames {
            fixture.store.save(frame: frame, for: .simple)
            XCTAssertEqual(fixture.store.storedFrame(for: .simple), valid)
        }

        fixture.defaults.set("not-a-frame", forKey: "menuBar.panelFrame.advanced")
        XCTAssertNil(fixture.store.storedFrame(for: .complex))
    }

    func testResolvedFrameUsesTheDisplayContainingTheCurrentAnchor() throws {
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let preferred = NSRect(x: 0, y: 0, width: 1_200, height: 900)
        let secondary = NSRect(x: -1_440, y: -120, width: 1_440, height: 900)
        let stored = NSRect(x: -1_400, y: 500, width: 700, height: 500)
        fixture.store.save(frame: stored, for: .geek)

        let resolved = fixture.store.resolvedFrame(
            for: .geek,
            anchor: NSRect(x: 600, y: 870, width: 24, height: 20),
            preferredVisibleFrame: preferred,
            availableVisibleFrames: [preferred, secondary]
        )

        XCTAssertTrue(preferred.insetBy(dx: 8, dy: 8).contains(resolved))
        XCTAssertFalse(secondary.intersects(resolved))
        XCTAssertEqual(resolved.midX, 612, accuracy: 0.001)
        XCTAssertEqual(resolved.size, PanelDensity.geek.idealSize)
    }

    func testResolvedFrameClampsFullyOffscreenFrameToPreferredDisplay() throws {
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let preferred = NSRect(x: 100, y: 50, width: 1_100, height: 800)
        fixture.store.save(
            frame: NSRect(x: 9_000, y: 8_000, width: 2_000, height: 1_500),
            for: .complex
        )

        let resolved = fixture.store.resolvedFrame(
            for: .complex,
            anchor: NSRect(x: 600, y: 830, width: 24, height: 20),
            preferredVisibleFrame: preferred,
            availableVisibleFrames: [preferred]
        )
        let bounds = preferred.insetBy(dx: 8, dy: 8)

        XCTAssertTrue(bounds.contains(resolved))
        XCTAssertEqual(resolved.size, PanelDensity.complex.idealSize)
        XCTAssertEqual(resolved.midX, 612, accuracy: 0.001)
        XCTAssertEqual(
            resolved.maxY,
            830 - MiniWindowStyleTokens.anchorGap,
            accuracy: 0.001
        )
    }

    func testPlacementCentersBelowAnchorAndKeepsEveryDensityInsideVisibleFrame() {
        let anchor = NSRect(x: 488, y: 875, width: 24, height: 24)
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 900)

        for density in PanelDensity.allCases {
            let frame = MenuBarPanelPlacement.frame(
                anchor: anchor,
                contentSize: density.idealSize,
                visibleFrame: visible,
                margin: 8
            )

            XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(frame))
            XCTAssertEqual(
                frame.maxY,
                anchor.minY - MiniWindowStyleTokens.anchorGap,
                accuracy: 0.001
            )
            XCTAssertEqual(frame.midX, anchor.midX, accuracy: 0.001)
        }
    }

    func testPlacementSupportsNegativeCoordinatesAndOversizedContent() {
        let negativeVisible = NSRect(x: -1_440, y: -120, width: 1_440, height: 900)
        let negativeFrame = MenuBarPanelPlacement.frame(
            anchor: NSRect(x: -80, y: 756, width: 22, height: 22),
            contentSize: PanelDensity.simple.idealSize,
            visibleFrame: negativeVisible
        )
        XCTAssertTrue(negativeVisible.insetBy(dx: 8, dy: 8).contains(negativeFrame))

        let smallVisible = NSRect(x: 10, y: 20, width: 500, height: 400)
        let bounds = smallVisible.insetBy(dx: 8, dy: 8)
        let oversizedFrame = MenuBarPanelPlacement.frame(
            anchor: NSRect(x: 240, y: 390, width: 24, height: 24),
            contentSize: NSSize(width: 1_000, height: 900),
            visibleFrame: smallVisible
        )
        XCTAssertEqual(oversizedFrame, bounds)
    }

    func testStatusItemAnchorFallsBackToMouseOnlyWhenTheButtonFrameIsMissing() {
        let buttonFrame = NSRect(x: 1_320, y: 875, width: 24, height: 22)
        let mouse = NSPoint(x: 420, y: 310)

        XCTAssertEqual(
            MenuBarPanelPlacement.anchor(statusItemFrame: buttonFrame, fallbackPoint: mouse),
            buttonFrame
        )
        XCTAssertEqual(
            MenuBarPanelPlacement.anchor(statusItemFrame: nil, fallbackPoint: mouse),
            NSRect(x: 420, y: 310, width: 1, height: 1)
        )
        XCTAssertEqual(
            MenuBarPanelPlacement.anchor(statusItemFrame: .zero, fallbackPoint: mouse),
            NSRect(x: 420, y: 310, width: 1, height: 1)
        )
    }

    func testCascadeStacksBelowWhenNeitherHorizontalSideFits() throws {
        let visible = NSRect(x: 0, y: 0, width: 700, height: 1_300)
        let parent = NSRect(
            x: 200,
            y: 700,
            width: MiniWindowStyleTokens.overviewSize.width,
            height: MiniWindowStyleTokens.overviewSize.height
        )
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: parent,
            childSizes: [NSSize(width: GeekPanelPresentationMetrics.detailWidth, height: 561)],
            visibleFrame: visible
        )
        let child = try XCTUnwrap(layout.childFrames.first)

        XCTAssertEqual(layout.direction, .left)
        XCTAssertEqual(layout.secondaryPresentationMode, .adjacent)
        XCTAssertEqual(parent.minY - child.maxY, MiniWindowStyleTokens.cascadeGap, accuracy: 0.001)
        XCTAssertEqual(child.maxX, parent.maxX, accuracy: 0.001)
        assertDisjointAndVisible([parent, child], visibleFrame: visible)
        XCTAssertEqual(
            layout.localFrame(for: child).minY,
            parent.height + MiniWindowStyleTokens.cascadeGap,
            accuracy: 0.001
        )
    }

    func testCascadeStacksTheWholeHierarchyBeforeDroppingTertiaryColumn() throws {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 2_600)
        let parent = NSRect(
            x: 250,
            y: 1_300,
            width: MiniWindowStyleTokens.overviewSize.width,
            height: MiniWindowStyleTokens.overviewSize.height
        )
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: parent,
            childSizes: [
                NSSize(width: GeekPanelPresentationMetrics.detailWidth, height: 561),
                MenuBarPanelPlacement.tertiaryColumnSize,
            ],
            visibleFrame: visible
        )
        let detail = try XCTUnwrap(layout.childFrames.first)
        let history = try XCTUnwrap(layout.childFrames.last)

        XCTAssertEqual(layout.secondaryPresentationMode, .adjacent)
        XCTAssertEqual(layout.tertiaryPresentationMode, .column)
        XCTAssertEqual(parent.minY - detail.maxY, MiniWindowStyleTokens.cascadeGap, accuracy: 0.001)
        XCTAssertEqual(detail.minY - history.maxY, MiniWindowStyleTokens.cascadeGap, accuracy: 0.001)
        assertDisjointAndVisible([parent, detail, history], visibleFrame: visible)
    }

    func testCascadeDropsTertiaryInsteadOfOverlappingParent() throws {
        let gap: CGFloat = 3
        let visible = NSRect(x: 0, y: 0, width: 1_208, height: 700)
        let margin: CGFloat = 8
        let requiredWidth = GeekPanelPresentationMetrics.detailWidth
            + MenuBarPanelPlacement.tertiaryColumnSize.width
            + gap * 2
        let parent = NSRect(
            x: visible.minX + margin + requiredWidth - gap * 2,
            y: 100,
            width: MiniWindowStyleTokens.overviewSize.width,
            height: MiniWindowStyleTokens.overviewSize.height
        )
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: parent,
            childSizes: [
                NSSize(width: GeekPanelPresentationMetrics.detailWidth, height: 561),
                MenuBarPanelPlacement.tertiaryColumnSize,
            ],
            visibleFrame: visible,
            gap: gap
        )
        let child = try XCTUnwrap(layout.childFrames.first)

        XCTAssertEqual(layout.direction, .left)
        XCTAssertEqual(layout.secondaryPresentationMode, .adjacent)
        XCTAssertEqual(layout.tertiaryPresentationMode, .unavailable)
        XCTAssertEqual(layout.childFrames.count, 1)
        XCTAssertEqual(parent.minX - child.maxX, gap, accuracy: 0.001)
        assertDisjointAndVisible([parent, child], visibleFrame: visible)
    }

    func testCascadeRejectsOversizedChildInsteadOfCompressingItsFrame() {
        let visible = NSRect(x: 0, y: 0, width: 700, height: 1_300)
        let bounds = visible.insetBy(dx: 8, dy: 8)
        let parent = NSRect(
            x: 200,
            y: 700,
            width: MiniWindowStyleTokens.overviewSize.width,
            height: MiniWindowStyleTokens.overviewSize.height
        )
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: parent,
            childSizes: [NSSize(width: bounds.width + 1, height: 200)],
            visibleFrame: visible
        )

        XCTAssertEqual(layout.secondaryPresentationMode, .unavailable)
        XCTAssertTrue(layout.childFrames.isEmpty)
    }

    func testCascadeKeepsPrimaryFixedAndPlacesTertiaryOutsideSecondaryAtTheRightEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let primary = NSRect(
            origin: NSPoint(
                x: visible.maxX - 8 - MiniWindowStyleTokens.overviewSize.width,
                y: 339
            ),
            size: MiniWindowStyleTokens.overviewSize
        )
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: primary,
            childSizes: [NSSize(width: GeekPanelPresentationMetrics.detailWidth, height: 561), MenuBarPanelPlacement.tertiaryColumnSize],
            visibleFrame: visible
        )

        XCTAssertEqual(layout.direction, .left)
        XCTAssertEqual(layout.parentFrame, primary)
        XCTAssertEqual(layout.secondaryPresentationMode, .adjacent)
        XCTAssertEqual(layout.tertiaryPresentationMode, .column)
        XCTAssertEqual(layout.childFrames.count, 2)
        XCTAssertEqual(layout.childFrames[0].maxX, primary.minX - MiniWindowStyleTokens.cascadeGap, accuracy: 0.001)
        XCTAssertEqual(layout.childFrames[1].maxX, layout.childFrames[0].minX - MiniWindowStyleTokens.cascadeGap, accuracy: 0.001)
        assertDisjointAndVisible([primary] + layout.childFrames, visibleFrame: visible)
    }

    func testCascadeFlipsTheWholeThreeColumnChainWithoutMovingPrimaryAtTheLeftEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let primary = NSRect(x: 8, y: 339, width: MiniWindowStyleTokens.overviewSize.width, height: MiniWindowStyleTokens.overviewSize.height)
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: primary,
            childSizes: [NSSize(width: GeekPanelPresentationMetrics.detailWidth, height: 465), MenuBarPanelPlacement.tertiaryColumnSize],
            visibleFrame: visible
        )

        XCTAssertEqual(layout.direction, .right)
        XCTAssertEqual(layout.parentFrame, primary)
        XCTAssertEqual(layout.secondaryPresentationMode, .adjacent)
        XCTAssertEqual(layout.tertiaryPresentationMode, .column)
        XCTAssertEqual(layout.childFrames.count, 2)
        XCTAssertEqual(layout.childFrames[0].minX, primary.maxX + MiniWindowStyleTokens.cascadeGap, accuracy: 0.001)
        XCTAssertEqual(layout.childFrames[1].minX, layout.childFrames[0].maxX + MiniWindowStyleTokens.cascadeGap, accuracy: 0.001)
        assertDisjointAndVisible([primary] + layout.childFrames, visibleFrame: visible)
    }

    func testCascadeUsesTheSelectedExternalDisplayAndClampsEveryLevelVertically() {
        let external = NSRect(x: -1_920, y: -180, width: 1_920, height: 1_080)
        let primary = NSRect(x: -309, y: -172, width: MiniWindowStyleTokens.overviewSize.width, height: MiniWindowStyleTokens.overviewSize.height)
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: primary,
            childSizes: [NSSize(width: GeekPanelPresentationMetrics.detailWidth, height: 644), MenuBarPanelPlacement.tertiaryColumnSize],
            visibleFrame: external
        )
        let bounds = external.insetBy(dx: 8, dy: 8)

        XCTAssertEqual(layout.direction, .left)
        XCTAssertEqual(layout.parentFrame, primary)
        XCTAssertEqual(layout.secondaryPresentationMode, .adjacent)
        XCTAssertEqual(layout.tertiaryPresentationMode, .column)
        XCTAssertEqual(layout.childFrames.count, 2)
        for frame in layout.childFrames {
            XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY)
            XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY)
        }
        XCTAssertTrue(layout.childFrames.allSatisfy { bounds.contains($0) })
    }

    func testCascadeMarksTertiaryUnavailableWhenNeitherSideFitsThreeLevels() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let primary = NSRect(x: 350, y: 239, width: MiniWindowStyleTokens.overviewSize.width, height: MiniWindowStyleTokens.overviewSize.height)
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: primary,
            childSizes: [
                NSSize(width: GeekPanelPresentationMetrics.detailWidth, height: 561),
                MenuBarPanelPlacement.tertiaryMaximumSize,
            ],
            visibleFrame: visible
        )

        XCTAssertEqual(layout.direction, .left)
        XCTAssertEqual(layout.parentFrame, primary)
        XCTAssertEqual(layout.secondaryPresentationMode, .adjacent)
        XCTAssertEqual(layout.tertiaryPresentationMode, .unavailable)
        XCTAssertEqual(layout.childFrames.count, 1)
        XCTAssertEqual(layout.childFrames[0].maxX, primary.minX - MiniWindowStyleTokens.cascadeGap, accuracy: 0.001)
        assertDisjointAndVisible([primary] + layout.childFrames, visibleFrame: visible)
    }

    func testCascadeMarksBothChildrenUnavailableRatherThanCoveringPrimary() {
        let visible = NSRect(x: 0, y: 0, width: 520, height: 800)
        let primary = NSRect(x: 109.5, y: 239, width: MiniWindowStyleTokens.overviewSize.width, height: MiniWindowStyleTokens.overviewSize.height)
        let layout = MenuBarPanelPlacement.cascade(
            parentFrame: primary,
            childSizes: [
                NSSize(width: GeekPanelPresentationMetrics.detailWidth, height: 483),
                MenuBarPanelPlacement.tertiaryMaximumSize,
            ],
            visibleFrame: visible
        )
        XCTAssertEqual(layout.parentFrame, primary)
        XCTAssertEqual(layout.secondaryPresentationMode, .unavailable)
        XCTAssertEqual(layout.tertiaryPresentationMode, .unavailable)
        XCTAssertTrue(layout.childFrames.isEmpty)
    }

    func testDetachedPlacementFlipsWhenPreferredSideCannotFit() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let decision = MenuBarPanelPlacement.detachedPanel(
            anchor: NSRect(x: 20, y: 400, width: 120, height: 40),
            size: NSSize(width: 280, height: 240),
            visibleFrame: visible,
            preferredEdges: [.left, .right],
            gap: 8
        )

        XCTAssertEqual(decision.edge, .right)
        XCTAssertEqual(decision.frame.minX, 148, accuracy: 0.001)
        XCTAssertTrue(visible.contains(decision.frame))
    }

    func testDetachedPlacementClampsPerpendicularAxisWithoutChangingSide() {
        let visible = NSRect(x: 0, y: 70, width: 1_000, height: 730)
        let decision = MenuBarPanelPlacement.detachedPanel(
            anchor: NSRect(x: 700, y: 760, width: 200, height: 30),
            size: NSSize(width: 250, height: 420),
            visibleFrame: visible,
            preferredEdges: [.left, .right, .below],
            gap: 8,
            avoidFrames: [NSRect(x: 650, y: 200, width: 300, height: 590)]
        )

        XCTAssertEqual(decision.edge, .left)
        XCTAssertEqual(decision.frame.maxX, 692, accuracy: 0.001)
        XCTAssertEqual(decision.frame.maxY, 790, accuracy: 0.001)
    }

    func testDetachedPlacementUsesDockAdjustedVisibleFrames() {
        let visibleFrames = [
            NSRect(x: 80, y: 0, width: 1_120, height: 800),
            NSRect(x: 0, y: 0, width: 1_120, height: 800),
            NSRect(x: 0, y: 70, width: 1_200, height: 730),
        ]
        for visible in visibleFrames {
            let decision = MenuBarPanelPlacement.detachedPanel(
                anchor: NSRect(x: visible.midX, y: visible.midY, width: 80, height: 40),
                size: NSSize(width: 260, height: 360),
                visibleFrame: visible,
                preferredEdges: [.left, .right, .below, .above],
                gap: 8
            )
            XCTAssertTrue(visible.contains(decision.frame), "Outside \(visible)")
        }
    }

    func testDetachedPlacementHysteresisKeepsPreviousEdgeForSmallMovement() {
        let visible = NSRect(x: 0, y: 0, width: 1_400, height: 900)
        let decision = MenuBarPanelPlacement.detachedPanel(
            anchor: NSRect(x: 620.4, y: 420.3, width: 160, height: 44),
            size: NSSize(width: 260, height: 300),
            visibleFrame: visible,
            preferredEdges: [.left, .right],
            previousEdge: .right,
            gap: 8,
            backingScaleFactor: 2
        )

        XCTAssertEqual(decision.edge, .right)
        XCTAssertFalse(decision.flipped)
    }

    func testPixelAlignmentIsStableAtOneAndTwoX() {
        let frame = NSRect(x: 10.26, y: -40.24, width: 301.27, height: 200.26)
        let oneX = MenuBarPanelPlacement.pixelAligned(frame, scale: 1)
        let twoX = MenuBarPanelPlacement.pixelAligned(frame, scale: 2)

        XCTAssertEqual(oneX.minX, oneX.minX.rounded())
        XCTAssertEqual(oneX.minY, oneX.minY.rounded())
        XCTAssertEqual(twoX.minX * 2, (twoX.minX * 2).rounded())
        XCTAssertEqual(twoX.minY * 2, (twoX.minY * 2).rounded())
    }

    func testDetachedPlacementConstrainsPanelTallerThanVisibleFrame() {
        let visible = NSRect(x: -1_920, y: -120, width: 1_920, height: 700)
        let decision = MenuBarPanelPlacement.detachedPanel(
            anchor: NSRect(x: -500, y: 400, width: 100, height: 40),
            size: NSSize(width: 300, height: 900),
            visibleFrame: visible,
            preferredEdges: [.left, .right],
            gap: 8,
            backingScaleFactor: 2
        )

        XCTAssertEqual(decision.frame.height, visible.height)
        XCTAssertTrue(visible.contains(decision.frame))
    }

    private func assertDisjointAndVisible(
        _ frames: [NSRect],
        visibleFrame: NSRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        for frame in frames {
            XCTAssertTrue(bounds.contains(frame), "\(frame) outside \(bounds)", file: file, line: line)
        }
        for firstIndex in frames.indices {
            for secondIndex in frames.indices where secondIndex > firstIndex {
                let intersection = frames[firstIndex].intersection(frames[secondIndex])
                XCTAssertTrue(
                    intersection.isNull || intersection.width == 0 || intersection.height == 0,
                    "\(frames[firstIndex]) overlaps \(frames[secondIndex])",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func makeGeometryFixture() throws -> (
        store: PanelGeometryStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "MenuBarPanelPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (PanelGeometryStore(defaults: defaults), defaults, suiteName)
    }
}
