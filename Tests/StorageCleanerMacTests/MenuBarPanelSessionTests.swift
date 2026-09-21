import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MenuBarPanelSessionTests: XCTestCase {
    func testAnchorGeometryPublishesAfterLayoutUsingOnlyTheLatestFrame() async {
        let panel = makePanel()
        defer { panel.close() }
        let anchor = SmallWindowAnchorNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        var reported: [NSRect] = []
        anchor.onSnapshotChanged = { rect, _ in reported.append(rect) }
        panel.contentView?.addSubview(anchor)
        anchor.frame.origin.x = 12
        anchor.layout()
        anchor.frame.origin.x = 24
        anchor.layout()

        XCTAssertTrue(reported.isEmpty, "A layout callback must not reenter SwiftUI state publication")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(reported, [panel.convertToScreen(anchor.convert(anchor.bounds, to: nil))])
    }

    func testDetachedAnchorDoesNotPublishItsQueuedGeometry() async {
        let panel = makePanel()
        defer { panel.close() }
        let anchor = SmallWindowAnchorNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        var reports = 0
        anchor.onSnapshotChanged = { _, _ in reports += 1 }
        panel.contentView?.addSubview(anchor)
        anchor.removeFromSuperview()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(reports, 0, "A removed hover target must not reposition a later menu")
    }

    func testUnpinnedMenuPanelStillAppearsAboveOrdinaryAppWindows() {
        let panel = makePanel()
        defer { panel.close() }
        panel.setAlwaysOnTop(false)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
        let transientLevel = panel.level
        panel.setAlwaysOnTop(true)
        XCTAssertGreaterThan(panel.level.rawValue, transientLevel.rawValue)
    }

    func testInteractionDiagnosticsAcceptNonMouseLaunchAndKeyboardEvents() throws {
        let launch = try XCTUnwrap(NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 12.5, windowNumber: 0, context: nil,
            subtype: 0, data1: 0, data2: 0
        ))
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 13.5, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        // Reading eventNumber on either event raises an Objective-C exception.
        for event in [launch, escape] {
            PerformanceTelemetry.panelInput("regression", target: "test", event: event)
        }
        XCTAssertEqual(launch.type, .applicationDefined)
        XCTAssertEqual(escape.keyCode, 53)
    }

    func testUnknownGlobalSourceWithinVisibleCascadeIsNotAnOutsideClick() throws {
        let screen = try requireScreen()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(panel: makePanel(), geometryStore: fixture.store,
                                  fixedVisibleFrame: Self.deterministicVisibleFrame, presentsPanelOnShow: false)
        defer { session.teardown() }
        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        session.setGeekSection(.memory)
        for frame in session.visibleAttachedContentFramesForTesting {
            XCTAssertFalse(session.handleMouseDown(
                sourceWindow: nil,
                screenLocation: NSPoint(x: frame.midX, y: frame.midY)
            ))
            XCTAssertTrue(session.isPresented)
        }
        XCTAssertTrue(session.handleMouseDown(
            sourceWindow: nil,
            screenLocation: NSPoint(x: session.panel.frame.maxX + 20, y: session.panel.frame.maxY + 20)
        ))
        XCTAssertFalse(session.isPresented)
    }

    func testKnownForeignWindowAtSameCoordinatesStillDismisses() throws {
        let screen = try requireScreen()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(panel: makePanel(), geometryStore: fixture.store,
                                  fixedVisibleFrame: Self.deterministicVisibleFrame, presentsPanelOnShow: false)
        defer { session.teardown() }
        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        XCTAssertTrue(session.handleMouseDown(
            sourceWindow: nil,
            screenLocation: NSPoint(x: session.panel.frame.midX, y: session.panel.frame.midY),
            eventWindowNumber: Int.max
        ))
        XCTAssertFalse(session.isPresented)
    }

    func testExplicitHistorySelectionSurvivesOtherHoverUntilAnotherClick() {
        let coordinator = GeekPanelCoordinator()
        coordinator.selectModule(.processor)
        XCTAssertTrue(coordinator.presentHistory(.builtIn("cpu"), pinned: true))
        XCTAssertFalse(coordinator.presentHistory(.builtIn("gpu"), pinned: false))
        XCTAssertEqual(coordinator.route, .history(module: .processor, selection: .builtIn("cpu")))
        XCTAssertTrue(coordinator.isHistoryPinned)
        XCTAssertTrue(coordinator.presentHistory(.builtIn("gpu"), pinned: true))
        XCTAssertEqual(coordinator.route, .history(module: .processor, selection: .builtIn("gpu")))
    }

    private static let deterministicVisibleFrame = NSRect(
        x: 0,
        y: 0,
        width: 1_440,
        height: 900
    )

    private final class PointerLocationBox {
        var value: NSPoint

        init(_ value: NSPoint) {
            self.value = value
        }
    }

    #if DEBUG || STORAGE_CLEANER_BETA
    func testDebugSnapshotRejectsTransparentFrameAndAcceptsVisiblePixels() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))

        XCTAssertFalse(MenuBarPanelSession.debugSnapshotHasVisiblePixels(bitmap))
        let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst)
            ? 0
            : bitmap.bitsPerPixel / 8 - 1
        bitmap.bitmapData?[4 * bitmap.bytesPerRow + 4 * (bitmap.bitsPerPixel / 8) + alphaOffset] = 255
        XCTAssertTrue(MenuBarPanelSession.debugSnapshotHasVisiblePixels(bitmap))
    }
    #endif

    func testDensitySelectionReusesPanelSessionAndHostingController() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer {
            panel.close()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        let session = makeSession(
            panel: panel,
            initialDensity: .simple,
            geometryStore: fixture.store
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .simple)
        let sessionIdentity = ObjectIdentifier(session)
        let panelIdentity = ObjectIdentifier(panel)
        let hostingController = try XCTUnwrap(
            panel.contentViewController as? NSHostingController<AnyView>
        )
        let hostingView = hostingController.view

        for density in PanelDensity.allCases {
            session.selectDensity(density)

            XCTAssertEqual(ObjectIdentifier(session), sessionIdentity)
            XCTAssertEqual(ObjectIdentifier(session.panel), panelIdentity)
            XCTAssertTrue(panel.contentViewController === hostingController)
            XCTAssertTrue(panel.contentView === hostingView)
            XCTAssertEqual(session.density, density)
            XCTAssertEqual(panel.frame.size, density.idealSize)
            XCTAssertEqual(panel.contentMinSize, density.idealSize)
            XCTAssertEqual(panel.contentMaxSize, density.idealSize)
        }
    }

    func testHoverIntentInvalidatesAnOlderDelayedPreview() {
        let coordinator = GeekPanelCoordinator()
        let olderIntent = coordinator.beginHoverIntent()
        let newerIntent = coordinator.beginHoverIntent()

        XCTAssertFalse(coordinator.isCurrentHoverIntent(olderIntent))
        XCTAssertTrue(coordinator.isCurrentHoverIntent(newerIntent))

        // An ended callback from the old card must not cancel the newer
        // card's delayed reveal.
        coordinator.invalidateHoverIntent(olderIntent)
        XCTAssertTrue(coordinator.isCurrentHoverIntent(newerIntent))

        coordinator.previewModule(.network)
        XCTAssertEqual(coordinator.route, .module(.network))
        XCTAssertFalse(coordinator.isCurrentHoverIntent(newerIntent))
    }

    func testSwitchingDetailedAndGeekPreservesTheCurrentAttachedSection() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        let session = makeSession(
            panel: panel,
            initialDensity: .complex,
            geometryStore: fixture.store
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .complex)
        session.setGeekSection(.network)
        XCTAssertEqual(session.geekSection, .network)

        session.selectDensity(.geek)

        XCTAssertEqual(session.geekSection, .network)
        XCTAssertEqual(
            panel.frame.size,
            GeekPanelPresentationMetrics.expandedSize(for: .network, density: .geek)
        )

        session.setGeekSection(.sensors)
        XCTAssertEqual(session.geekSection, .sensors)

        session.selectDensity(.complex)

        XCTAssertEqual(session.geekSection, .sensors)
        XCTAssertEqual(
            panel.frame.size,
            GeekPanelPresentationMetrics.expandedSize(for: .sensors, density: .complex)
        )
    }

    func testDetailedAndGeekDetailsExpandTheSameFixedPanelAndKeepOverviewAnchored() throws {
        let screen = try requireScreen()

        try [PanelDensity.complex, .geek].forEach { density in
            let panel = makePanel()
            let fixture = try makeGeometryFixture()
            defer {
                fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
            }
            let session = makeSession(
                panel: panel,
                initialDensity: density,
                geometryStore: fixture.store,
                fixedVisibleFrame: Self.deterministicVisibleFrame,
                presentsPanelOnShow: false
            )
            defer { session.teardown() }

            session.show(
                anchor: makeAnchor(in: Self.deterministicVisibleFrame),
                screen: screen,
                density: density
            )
            let panelIdentity = ObjectIdentifier(panel)
            let hostingController = try XCTUnwrap(panel.contentViewController)
            let overviewFrame = panel.frame

            session.setGeekSection(.processor)

            XCTAssertEqual(ObjectIdentifier(session.panel), panelIdentity, density.rawValue)
            XCTAssertTrue(panel.contentViewController === hostingController, density.rawValue)
            XCTAssertEqual(session.geekSection, .processor, density.rawValue)
            XCTAssertEqual(
                panel.frame.size,
                GeekPanelPresentationMetrics.expandedSize(
                    for: .processor,
                    density: density
                ),
                density.rawValue
            )
            XCTAssertEqual(panel.contentMinSize, panel.frame.size, density.rawValue)
            XCTAssertEqual(panel.contentMaxSize, panel.frame.size, density.rawValue)
            XCTAssertEqual(panel.frame.maxX, overviewFrame.maxX, accuracy: 0.5)
            XCTAssertTrue(
                session.visibleAttachedContentFramesForTesting.contains {
                    approximatelyEqual($0, overviewFrame)
                },
                density.rawValue
            )
            XCTAssertFalse(panel.styleMask.contains(.resizable), density.rawValue)

            session.setGeekSection(.overview)

            XCTAssertEqual(session.geekSection, .overview, density.rawValue)
            assertRect(panel.frame, equals: overviewFrame)
            XCTAssertEqual(panel.contentMinSize, density.idealSize, density.rawValue)
            XCTAssertEqual(panel.contentMaxSize, density.idealSize, density.rawValue)
        }
    }

    func testMeasuredOverviewHeightIsNotCappedByStartupReferenceAndRejectsInvalidSizes() {
        let measured = CGSize(width: 304, height: 564)
        XCTAssertEqual(GeekPanelPresentationMetrics.normalizedOverviewSize(measured), measured)
        for height in [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity, 0, -1] {
            XCTAssertEqual(
                GeekPanelPresentationMetrics.normalizedOverviewSize(CGSize(width: 304, height: height)),
                GeekPanelPresentationMetrics.overviewSize
            )
        }
        XCTAssertEqual(
            GeekPanelPresentationMetrics.normalizedOverviewSize(CGSize(width: CGFloat.nan, height: 564)),
            GeekPanelPresentationMetrics.overviewSize
        )
    }

    func testMeasuredOverviewSizeAppliesOnFirstShowAndSurvivesReopenAndRepeatedUpdates() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let measured = CGSize(width: 304, height: 564)
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            initialOverviewSize: measured,
            fixedVisibleFrame: Self.deterministicVisibleFrame,
            presentsPanelOnShow: false
        )
        defer { session.teardown() }
        let anchor = makeAnchor(in: Self.deterministicVisibleFrame)
        session.show(anchor: anchor, screen: screen, density: .geek)
        let firstFrame = panel.frame
        XCTAssertEqual(firstFrame.size, measured)
        XCTAssertEqual(panel.contentMinSize, measured)
        XCTAssertEqual(panel.contentMaxSize, measured)
        session.setOverviewSize(measured)
        XCTAssertEqual(panel.frame, firstFrame)
        session.hide()
        session.show(anchor: anchor, screen: screen, density: .geek)
        XCTAssertEqual(panel.frame, firstFrame)
        session.setOverviewSize(CGSize(width: 304, height: 280))
        session.setOverviewSize(measured)
        XCTAssertEqual(panel.frame, firstFrame)
    }

    func testBatterylessOverviewShrinksFromTheBottomAndKeepsAttachedGeometry() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            geometryStore: fixture.store,
            fixedVisibleFrame: Self.deterministicVisibleFrame,
            presentsPanelOnShow: false
        )
        defer { session.teardown() }

        session.show(
            anchor: makeAnchor(in: Self.deterministicVisibleFrame),
            screen: screen,
            density: .geek
        )
        let fullFrame = panel.frame
        let batterylessSize = GeekPanelLayout.overviewSize(
            showsPowerModule: false
        )

        session.setOverviewSize(batterylessSize)

        XCTAssertEqual(session.overviewSize, batterylessSize)
        XCTAssertEqual(panel.frame.size, batterylessSize)
        XCTAssertEqual(panel.frame.maxY, fullFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(panel.contentMinSize, batterylessSize)
        XCTAssertEqual(panel.contentMaxSize, batterylessSize)

        session.setGeekSection(.sensors)

        let frames = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[1].size, batterylessSize)
        XCTAssertEqual(frames[1].maxY, fullFrame.maxY, accuracy: 0.001)
        assertPairwiseDisjoint(frames)
    }

    func testEveryGeekDetailAvoidsGrowingBelowItsOwnVisibleSurfaces() {
        for section in PanelSection.allCases where section != .overview {
            let detailSize = GeekPanelPresentationMetrics.detailSize(for: section)
            let expandedSize = GeekPanelPresentationMetrics.expandedSize(for: section)

            XCTAssertEqual(
                expandedSize.height,
                max(GeekPanelPresentationMetrics.overviewSize.height, detailSize.height),
                "Expected \(section) to slide upward instead of adding an off-screen transparent tail"
            )
        }
    }

    func testMeasuredSecondaryContentShrinksItsVisibleSurfaceWithoutMovingOverview() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            geometryStore: fixture.store,
            fixedVisibleFrame: Self.deterministicVisibleFrame
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        let overviewFrame = panel.frame
        session.setGeekSection(.memory)

        let measuredContentSize = CGSize(width: 999, height: 220)
        session.setDetailSize(measuredContentSize)

        let expectedDetailSize = CGSize(
            width: GeekPanelPresentationMetrics.detailWidth,
            height: measuredContentSize.height
        )
        XCTAssertEqual(session.detailColumnSize, expectedDetailSize)
        XCTAssertEqual(panel.frame.height, GeekPanelPresentationMetrics.overviewSize.height)

        session.setTertiaryPresented(
            true,
            preferredSize: CGSize(width: 170, height: 167)
        )
        XCTAssertEqual(session.detailColumnSize, expectedDetailSize)
        session.setTertiaryPresented(false)

        let frames = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].size, expectedDetailSize)
        XCTAssertTrue(frames.contains { approximatelyEqual($0, overviewFrame) })
        XCTAssertEqual(frames[0].maxY, frames[1].maxY - 135, accuracy: 0.001)
        assertPairwiseDisjoint(frames)

        XCTAssertTrue(session.handleMouseDown(
            sourceWindow: panel,
            screenLocation: NSPoint(x: frames[0].midX, y: frames[0].minY - 10)
        ))
        XCTAssertFalse(session.isPresented)
        XCTAssertFalse(session.isTornDown)
    }

    func testTertiaryOffsetKeepsTheOwningRowInsteadOfClampingToAColumnEdge() {
        for density in [PanelDensity.complex, .geek] {
            for section in [PanelSection.disk, .power] {
                let twoColumnSize = GeekPanelPresentationMetrics.expandedSize(
                    for: section,
                    density: density
                )
                let sourceOffset: CGFloat = 360
                let tertiaryOffset = GeekPanelPresentationMetrics.tertiaryVerticalOffset(
                    for: section,
                    density: density,
                    sourceOffset: sourceOffset
                )

                XCTAssertEqual(
                    tertiaryOffset,
                    GeekPanelPresentationMetrics.detailVerticalOffset(
                        for: section,
                        density: density
                    ) + sourceOffset,
                    "\(density)-\(section)"
                )
                XCTAssertGreaterThan(
                    tertiaryOffset + GeekPanelPresentationMetrics.tertiarySize.height,
                    twoColumnSize.height,
                    "\(density)-\(section)"
                )
            }
        }
    }

    func testInlineTertiaryAlignsItsTopWithTheOwningSecondaryRow() throws {
        let screen = try requireScreen()
        let wideVisibleFrame = NSRect(x: 0, y: 0, width: 2_400, height: 1_200)
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            geometryStore: fixture.store,
            fixedVisibleFrame: wideVisibleFrame
        )
        defer { session.teardown() }

        let anchor = makeAnchor(in: wideVisibleFrame)
        session.show(anchor: anchor, screen: screen, density: .geek)
        let panelIdentity = ObjectIdentifier(panel)
        let hostingController = try XCTUnwrap(panel.contentViewController)
        session.setGeekSection(.power)

        let energyModeSize = CGSize(width: 170, height: 167)
        session.setTertiaryPresented(
            true,
            preferredSize: energyModeSize,
            sourceOffset: 300
        )

        XCTAssertEqual(ObjectIdentifier(session.panel), panelIdentity)
        XCTAssertTrue(panel.contentViewController === hostingController)
        XCTAssertEqual(session.tertiaryColumnSize, energyModeSize)
        XCTAssertEqual(session.tertiarySourceOffset, 300)
        XCTAssertEqual(panel.contentMinSize, panel.frame.size)
        XCTAssertEqual(panel.contentMaxSize, panel.frame.size)

        let frames = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(frames.count, 3)
        let tertiaryFrame = try XCTUnwrap(frames.last)
        XCTAssertEqual(tertiaryFrame.size, energyModeSize)
        XCTAssertEqual(
            GeekPanelPresentationMetrics.tertiaryVerticalOffset(
                for: .power,
                density: .geek,
                tertiarySize: energyModeSize,
                sourceOffset: 300
            ),
            479
        )
        let expectedDetailTopOffset = GeekPanelPresentationMetrics.detailVerticalOffset(
            for: .power,
            density: .geek
        )
        let expectedTertiaryTopOffset = GeekPanelPresentationMetrics.tertiaryVerticalOffset(
            for: .power,
            density: .geek,
            tertiarySize: energyModeSize,
            sourceOffset: 300
        )
        XCTAssertEqual(
            frames[0].maxY,
            frames[1].maxY - expectedDetailTopOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            tertiaryFrame.maxY,
            frames[0].maxY - 300,
            accuracy: 0.001
        )
        XCTAssertEqual(panel.frame.height, expectedTertiaryTopOffset + energyModeSize.height)
        XCTAssertGreaterThan(
            panel.frame.height,
            GeekPanelPresentationMetrics.overviewSize.height
        )
        assertPairwiseDisjoint(frames)

        let historySize = CGSize(width: MiniWindowStyleTokens.historyWidth, height: 216)
        session.setTertiaryPresented(
            true,
            preferredSize: historySize,
            sourceOffset: 20
        )

        XCTAssertEqual(ObjectIdentifier(session.panel), panelIdentity)
        XCTAssertTrue(panel.contentViewController === hostingController)
        XCTAssertEqual(session.tertiaryColumnSize, historySize)
        XCTAssertEqual(session.tertiarySourceOffset, 20)
        let historyFrames = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(historyFrames.last?.size, historySize)
        XCTAssertEqual(
            historyFrames[0].maxY,
            historyFrames[1].maxY - expectedDetailTopOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(historyFrames.last).maxY,
            historyFrames[1].maxY
                - GeekPanelPresentationMetrics.tertiaryVerticalOffset(
                    for: .power,
                    density: .geek,
                    tertiarySize: historySize,
                    sourceOffset: 20
                ),
            accuracy: 0.001
        )
        XCTAssertEqual(
            panel.frame.width,
            GeekPanelPresentationMetrics.expandedSize(
                for: .power,
                density: .geek,
                includesTertiaryColumn: true,
                tertiarySize: historySize
            ).width,
            accuracy: 0.001
        )

        session.setTertiaryPresented(false)
        XCTAssertFalse(session.isTertiaryPresented)
        XCTAssertEqual(session.tertiaryColumnSize, GeekPanelPresentationMetrics.tertiarySize)
        XCTAssertNil(session.tertiarySourceOffset)
    }

    func testBatteryTertiaryAndPowerPaletteAreExclusiveAcrossRapidSwitches() throws {
        let screen = try requireScreen()
        let visibleFrame = NSRect(x: 0, y: 0, width: 2_400, height: 1_200)
        let panel = makePanel()
        let hoverController = HoverIntentController()
        let panelCoordinator = GeekPanelCoordinator(
            hoverIntentController: hoverController
        )
        let paletteCoordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: visibleFrame,
            presentsPanelOnShow: false,
            hoverIntentController: hoverController,
            pointerLocationProvider: { NSPoint(x: -10_000, y: -10_000) }
        )
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            panelCoordinator: panelCoordinator,
            controlPaletteCoordinator: paletteCoordinator,
            fixedVisibleFrame: visibleFrame,
            presentsPanelOnShow: false
        )
        defer { session.teardown() }

        session.show(
            anchor: makeAnchor(in: visibleFrame),
            screen: screen,
            density: .geek
        )
        panelCoordinator.selectModule(.power)
        session.setGeekSection(.power)
        let powerModeRow = NSRect(x: 640, y: 350, width: 280, height: 25)

        for index in 0..<100 {
            let selection = GeekPanelHistorySelection.inline(UUID())
            hoverController.markOpen(
                anchorID: .tertiary(String(describing: selection)),
                panelRole: .tertiary
            )
            panelCoordinator.presentHistory(selection, pinned: false)
            session.setTertiaryPresented(
                true,
                preferredSize: GeekSensorPowerHoverDetailMetrics.batterySize,
                sourceOffset: 0
            )

            XCTAssertTrue(session.isTertiaryPresented, "tertiary \(index)")
            XCTAssertFalse(paletteCoordinator.isPresented, "palette \(index)")
            guard case .open(_, .tertiary) = hoverController.state else {
                return XCTFail("Expected tertiary ownership at iteration \(index)")
            }

            paletteCoordinator.toggle(
                .power,
                anchorScreenRect: powerModeRow,
                parentWindow: panel
            )

            XCTAssertFalse(session.isTertiaryPresented, "tertiary \(index)")
            XCTAssertTrue(paletteCoordinator.isPresented, "palette \(index)")
            XCTAssertEqual(
                hoverController.state,
                .open(anchorID: .powerMode, panelRole: .controlPalette),
                "ownership \(index)"
            )
        }
    }

    func testFanPaletteRejectsStaleTertiaryCallbacksAcrossRepeatedSwitches() throws {
        let screen = try requireScreen()
        let visibleFrame = NSRect(x: 0, y: 0, width: 2_400, height: 1_200)
        let panel = makePanel()
        let hoverController = HoverIntentController()
        let panelCoordinator = GeekPanelCoordinator(
            hoverIntentController: hoverController
        )
        let paletteCoordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: visibleFrame,
            presentsPanelOnShow: false,
            hoverIntentController: hoverController,
            pointerLocationProvider: { NSPoint(x: -10_000, y: -10_000) }
        )
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            panelCoordinator: panelCoordinator,
            controlPaletteCoordinator: paletteCoordinator,
            fixedVisibleFrame: visibleFrame,
            presentsPanelOnShow: false
        )
        defer { session.teardown() }

        session.show(
            anchor: makeAnchor(in: visibleFrame),
            screen: screen,
            density: .geek
        )
        panelCoordinator.selectModule(.sensors)
        session.setGeekSection(.sensors)
        let fanAnchor = NSRect(x: 640, y: 350, width: 72, height: 72)

        for index in 0..<100 {
            panelCoordinator.presentHistory(.inline(UUID()), pinned: true)
            session.setTertiaryPresented(true)
            XCTAssertTrue(session.isTertiaryPresented, "tertiary \(index)")

            paletteCoordinator.toggle(
                .fan,
                anchorScreenRect: fanAnchor,
                parentWindow: panel
            )

            XCTAssertFalse(session.isTertiaryPresented, "collapsed \(index)")
            XCTAssertTrue(paletteCoordinator.isPresented, "palette \(index)")
            XCTAssertEqual(
                hoverController.state,
                .open(anchorID: .fanControl, panelRole: .controlPalette),
                "ownership \(index)"
            )
            XCTAssertTrue(panelCoordinator.isControlPalettePresented, "palette route \(index)")

            // Simulate both halves of the stale SwiftUI callback that
            // previously reopened tertiary after the palette won the switch.
            XCTAssertFalse(panelCoordinator.presentHistory(
                .inline(UUID()),
                pinned: false
            ), "stale route \(index)")
            session.setTertiaryPresented(true)

            XCTAssertFalse(session.isTertiaryPresented, "stale callback \(index)")
            XCTAssertTrue(paletteCoordinator.isPresented, "palette retained \(index)")
            XCTAssertTrue(session.visibleAttachedContentFramesForTesting.allSatisfy {
                !$0.intersects(paletteCoordinator.panel.frame)
            }, "geometry \(index)")

            // A new, intentional click must still replace the palette.
            XCTAssertTrue(panelCoordinator.presentHistory(.inline(UUID()), pinned: true))
            session.setTertiaryPresented(true)
            XCTAssertTrue(session.isTertiaryPresented, "intentional tertiary \(index)")
            XCTAssertFalse(paletteCoordinator.isPresented, "palette dismissed \(index)")
        }
    }

    /// Regression: hovering the power-mode row opened the palette, but any
    /// hover target crossed on the way to it (neighbor rows, the module
    /// rail) would steal the hover after the 15 ms switch delay and tear
    /// the palette down before the pointer could reach it.
    func testHoverPreviewsStandDownWhilePointerTravelsToPresentedPalette() async throws {
        let screen = try requireScreen()
        let visibleFrame = NSRect(x: 0, y: 0, width: 2_400, height: 1_200)
        let panel = makePanel()
        let hoverController = HoverIntentController()
        let panelCoordinator = GeekPanelCoordinator(hoverIntentController: hoverController)
        let palettePointer = PointerLocationBox(NSPoint(x: -10_000, y: -10_000))
        let paletteCoordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: visibleFrame,
            presentsPanelOnShow: false,
            hoverIntentController: hoverController,
            pointerLocationProvider: { palettePointer.value }
        )
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            panelCoordinator: panelCoordinator,
            controlPaletteCoordinator: paletteCoordinator,
            fixedVisibleFrame: visibleFrame,
            presentsPanelOnShow: false
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(in: visibleFrame), screen: screen, density: .geek)
        panelCoordinator.selectModule(.power)
        session.setGeekSection(.power)
        let powerModeRow = NSRect(
            x: panel.frame.midX - 140,
            y: panel.frame.midY,
            width: 280,
            height: 25
        )
        paletteCoordinator.toggle(.power, anchorScreenRect: powerModeRow, parentWindow: panel)
        XCTAssertTrue(paletteCoordinator.isPresented)
        let paletteFrame = paletteCoordinator.panel.frame
        XCTAssertLessThanOrEqual(
            paletteFrame.maxX,
            panel.frame.minX,
            "palette docks left of the window"
        )

        // Pointer mid-flight in the corridor between the row and the palette.
        palettePointer.value = NSPoint(
            x: (paletteFrame.maxX + powerModeRow.minX) / 2,
            y: powerModeRow.midY
        )

        var pendingCloseFired = false
        hoverController.scheduleClose(
            delay: .milliseconds(40),
            condition: { true },
            action: { pendingCloseFired = true }
        )

        var tertiaryStoleHover = false
        let tertiaryIntent = panelCoordinator.scheduleTertiaryPreview(
            identifier: "battery",
            condition: { true },
            action: { tertiaryStoleHover = true }
        )
        XCTAssertFalse(panelCoordinator.isCurrentHoverIntent(tertiaryIntent))

        var moduleStoleHover = false
        let moduleIntent = panelCoordinator.scheduleModulePreview(
            .processor,
            condition: { true },
            action: { moduleStoleHover = true }
        )
        XCTAssertFalse(panelCoordinator.isCurrentHoverIntent(moduleIntent))

        // The refusals must not cancel pending hover work either.
        let closeSurvived = await eventually { pendingCloseFired }
        XCTAssertTrue(closeSurvived)
        XCTAssertFalse(tertiaryStoleHover)
        XCTAssertFalse(moduleStoleHover)
        XCTAssertTrue(paletteCoordinator.isPresented)

        // Once the pointer abandons the palette the gate releases.
        palettePointer.value = NSPoint(x: -10_000, y: -10_000)
        var releasedPreviewFired = false
        let releasedIntent = panelCoordinator.scheduleTertiaryPreview(
            identifier: "battery",
            condition: { true },
            action: { releasedPreviewFired = true }
        )
        XCTAssertTrue(panelCoordinator.isCurrentHoverIntent(releasedIntent))
        let didRelease = await eventually { releasedPreviewFired }
        XCTAssertTrue(didRelease)
    }

    /// Regression companion: a scheduler-marked tertiary hover arriving via a
    /// direct `presentHistory` call must also stand down while the pointer is
    /// inside the palette envelope, and keep replacing the palette otherwise.
    func testPresentHistoryYieldsToPaletteOnlyWhileItClaimsThePointer() throws {
        let screen = try requireScreen()
        let visibleFrame = NSRect(x: 0, y: 0, width: 2_400, height: 1_200)
        let panel = makePanel()
        let hoverController = HoverIntentController()
        let panelCoordinator = GeekPanelCoordinator(hoverIntentController: hoverController)
        let palettePointer = PointerLocationBox(NSPoint(x: -10_000, y: -10_000))
        let paletteCoordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: visibleFrame,
            presentsPanelOnShow: false,
            hoverIntentController: hoverController,
            pointerLocationProvider: { palettePointer.value }
        )
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            panelCoordinator: panelCoordinator,
            controlPaletteCoordinator: paletteCoordinator,
            fixedVisibleFrame: visibleFrame,
            presentsPanelOnShow: false
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(in: visibleFrame), screen: screen, density: .geek)
        panelCoordinator.selectModule(.power)
        session.setGeekSection(.power)
        let powerModeRow = NSRect(
            x: panel.frame.midX - 140,
            y: panel.frame.midY,
            width: 280,
            height: 25
        )
        paletteCoordinator.toggle(.power, anchorScreenRect: powerModeRow, parentWindow: panel)
        XCTAssertTrue(paletteCoordinator.isPresented)

        // Pointer inside the palette: hover-driven history stands down.
        palettePointer.value = NSPoint(
            x: paletteCoordinator.panel.frame.midX,
            y: paletteCoordinator.panel.frame.midY
        )
        hoverController.markOpen(anchorID: .tertiary("battery"), panelRole: .tertiary)
        XCTAssertFalse(panelCoordinator.presentHistory(.inline(UUID()), pinned: false))
        XCTAssertTrue(paletteCoordinator.isPresented)
        XCTAssertEqual(panelCoordinator.route, .module(.power))

        // Pointer away from the palette: the tertiary replaces it as before.
        palettePointer.value = NSPoint(x: -10_000, y: -10_000)
        hoverController.markOpen(anchorID: .tertiary("battery"), panelRole: .tertiary)
        XCTAssertTrue(panelCoordinator.presentHistory(.inline(UUID()), pinned: false))
        guard case .history = panelCoordinator.route else {
            return XCTFail("Expected history route after the palette yielded")
        }
    }

    /// Regression: the session's hover envelope only covered the attached
    /// columns, so the trip from the window to the palette looked like
    /// leaving the panel and collapsed the unpinned hierarchy (and the
    /// palette with it) mid-flight.
    func testHoverEnvelopeIncludesPresentedPaletteFrame() throws {
        let screen = try requireScreen()
        let visibleFrame = NSRect(x: 0, y: 0, width: 2_400, height: 1_200)
        let panel = makePanel()
        let hoverController = HoverIntentController()
        let panelCoordinator = GeekPanelCoordinator(hoverIntentController: hoverController)
        let sessionPointer = PointerLocationBox(NSPoint(x: -10_000, y: -10_000))
        let paletteCoordinator = ControlPaletteCoordinator(
            fixedVisibleFrame: visibleFrame,
            presentsPanelOnShow: false,
            hoverIntentController: hoverController,
            pointerLocationProvider: { sessionPointer.value }
        )
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            panelCoordinator: panelCoordinator,
            controlPaletteCoordinator: paletteCoordinator,
            pointerLocationProvider: { sessionPointer.value },
            fixedVisibleFrame: visibleFrame,
            presentsPanelOnShow: false
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(in: visibleFrame), screen: screen, density: .geek)
        panelCoordinator.selectModule(.power)
        session.setGeekSection(.power)

        let leadingColumn = try XCTUnwrap(
            session.visibleAttachedContentFramesForTesting.min { $0.minX < $1.minX }
        )
        let rowInLeadingColumn = NSRect(
            x: leadingColumn.midX - 100,
            y: leadingColumn.midY,
            width: 200,
            height: 25
        )
        paletteCoordinator.toggle(
            .power,
            anchorScreenRect: rowInLeadingColumn,
            parentWindow: panel
        )
        XCTAssertTrue(paletteCoordinator.isPresented)
        let paletteFrame = paletteCoordinator.panel.frame
        XCTAssertLessThanOrEqual(
            paletteFrame.maxX,
            panel.frame.minX,
            "palette docks left of the window"
        )

        // Establish the hover origin inside the window, then cross the shared
        // edge into the palette: the envelope must hold on both sides.
        panel.onPointerLocationChanged?(
            NSPoint(x: rowInLeadingColumn.midX, y: rowInLeadingColumn.midY)
        )
        XCTAssertTrue(panelCoordinator.isPointerWithinHoverEnvelope)
        panel.onPointerLocationChanged?(
            NSPoint(x: paletteFrame.maxX - 10, y: rowInLeadingColumn.midY)
        )
        XCTAssertTrue(panelCoordinator.isPointerWithinHoverEnvelope)

        // Inside the palette, motion reported by the palette's own tracking
        // keeps the session envelope alive.
        paletteCoordinator.panel.onPointerLocationChanged?(
            NSPoint(x: paletteFrame.midX, y: paletteFrame.midY)
        )
        XCTAssertTrue(panelCoordinator.isPointerWithinHoverEnvelope)

        // Leaving everything still drops the envelope.
        panel.onPointerLocationChanged?(
            NSPoint(x: visibleFrame.maxX - 10, y: visibleFrame.minY + 10)
        )
        XCTAssertFalse(panelCoordinator.isPointerWithinHoverEnvelope)

        // Dismissing the palette resamples the live pointer so delayed
        // dismissal tasks never see a stale "contained" value.
        paletteCoordinator.panel.onPointerLocationChanged?(
            NSPoint(x: paletteFrame.midX, y: paletteFrame.midY)
        )
        XCTAssertTrue(panelCoordinator.isPointerWithinHoverEnvelope)
        sessionPointer.value = NSPoint(x: visibleFrame.maxX - 10, y: visibleFrame.minY + 10)
        paletteCoordinator.dismiss()
        XCTAssertFalse(panelCoordinator.isPointerWithinHoverEnvelope)
    }

    func testNetworkTrendAndConnectionDetailsShareTheAttachedThirdColumn() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            geometryStore: fixture.store
        )
        defer { session.teardown() }

        let anchor = NSRect(
            x: screen.visibleFrame.maxX - 32,
            y: screen.visibleFrame.maxY - 24,
            width: 24,
            height: 20
        )
        session.show(anchor: anchor, screen: screen, density: .geek)
        session.setGeekSection(.network)
        let panelIdentity = ObjectIdentifier(panel)
        let hostingController = try XCTUnwrap(panel.contentViewController)

        for size in [
            GeekHoverDetailMetrics.compactHistorySize,
            GeekNetworkTertiaryView.referenceSize,
        ] {
            session.setTertiaryPresented(true, preferredSize: size)

            XCTAssertEqual(ObjectIdentifier(session.panel), panelIdentity)
            XCTAssertTrue(panel.contentViewController === hostingController)
            XCTAssertEqual(session.tertiaryColumnSize, size)
            let frames = session.visibleAttachedContentFramesForTesting
            XCTAssertEqual(frames.count, 3)
            XCTAssertEqual(frames.last?.size, size)
            XCTAssertEqual(frames[0].maxY, frames[1].maxY, accuracy: 0.001)
            XCTAssertEqual(frames[2].maxY, frames[1].maxY, accuracy: 0.001)
            assertPairwiseDisjoint(frames)
        }
    }

    func testDetailedAndGeekProfilesUseTheSharedDetailWidth() {
        for section in PanelSection.allCases where section != .overview {
            let detailed = GeekPanelPresentationMetrics.detailSize(
                for: section,
                density: .complex
            )
            let geek = GeekPanelPresentationMetrics.detailSize(
                for: section,
                density: .geek
            )

            let expectedWidth = section == .power
                ? GeekPanelPresentationMetrics.powerDetailWidth
                : GeekPanelPresentationMetrics.detailWidth
            XCTAssertEqual(detailed.width, expectedWidth, section.rawValue)
            XCTAssertEqual(geek.width, expectedWidth, section.rawValue)
            XCTAssertLessThanOrEqual(detailed.height, geek.height, section.rawValue)
            XCTAssertEqual(
                GeekPanelPresentationMetrics.expandedSize(
                    for: section,
                    density: .complex
                ).height,
                GeekPanelPresentationMetrics.overviewSize.height,
                section.rawValue
            )
        }
    }

    func testDetailedAttachedPagesRemainAnchoredToTheirOverviewRows() {
        let expectedOffsets: [PanelSection: CGFloat] = [
            .processor: 0,
            .memory: 135,
            .disk: 254,
            .network: 0,
            .sensors: 130,
            .power: 287,
            .cleanup: 0,
        ]

        for (section, expectedOffset) in expectedOffsets {
            XCTAssertEqual(
                GeekPanelPresentationMetrics.detailVerticalOffset(
                    for: section,
                    density: .complex
                ),
                expectedOffset,
                section.rawValue
            )
            XCTAssertLessThanOrEqual(
                expectedOffset
                    + GeekPanelPresentationMetrics.detailSize(
                        for: section,
                        density: .complex
                    ).height,
                GeekPanelPresentationMetrics.overviewSize.height,
                section.rawValue
            )
        }
    }

    func testDetailedAndGeekExpansionRemainInsideTheVisibleScreenNearAnEdge() throws {
        let screen = try requireScreen()
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)

        try [PanelDensity.complex, .geek].forEach { density in
            let panel = makePanel()
            let fixture = try makeGeometryFixture()
            defer {
                fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
            }
            fixture.store.save(
                frame: NSRect(
                    x: visible.minX,
                    y: visible.maxY - density.idealSize.height,
                    width: density.idealSize.width,
                    height: density.idealSize.height
                ),
                for: density
            )
            let session = makeSession(
                panel: panel,
                initialDensity: density,
                geometryStore: fixture.store
            )
            defer { session.teardown() }

            session.show(anchor: makeAnchor(on: screen), screen: screen, density: density)
            session.setGeekSection(.sensors)

            XCTAssertTrue(visible.contains(panel.frame), density.rawValue)
            XCTAssertEqual(
                panel.frame.size,
                GeekPanelPresentationMetrics.expandedSize(
                    for: .sensors,
                    density: density
                ),
                density.rawValue
            )
        }
    }

    func testAttachedDetailFlipsRightWithoutMovingOverviewAtTheLeftEdge() throws {
        let screen = try requireScreen()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let panel = makePanel()
        let settingsState = MenuBarPanelSettingsState(
            initialDensity: .geek,
            defaults: fixture.defaults
        )
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            geometryStore: fixture.store,
            panelSettingsState: settingsState,
            fixedVisibleFrame: Self.deterministicVisibleFrame,
            presentsPanelOnShow: false
        )
        defer { session.teardown() }
        let anchor = NSRect(
            x: Self.deterministicVisibleFrame.minX + 8,
            y: Self.deterministicVisibleFrame.maxY - 20,
            width: 24,
            height: 20
        )

        session.show(anchor: anchor, screen: screen, density: .geek)
        let overviewFrame = panel.frame
        let panelIdentity = ObjectIdentifier(panel)
        let hostingController = try XCTUnwrap(panel.contentViewController)
        session.setGeekSection(.network)
        let twoColumnFrame = panel.frame

        XCTAssertEqual(session.cascadeDirection, .right)
        XCTAssertEqual(settingsState.cascadeDirection, .right)
        XCTAssertEqual(
            settingsState.tertiaryPresentationMode,
            session.tertiaryPresentationMode
        )
        XCTAssertEqual(panel.frame.minX, overviewFrame.minX, accuracy: 0.5)
        XCTAssertEqual(
            panel.frame.width,
            GeekPanelPresentationMetrics.expandedSize(for: .network, density: .geek).width,
            accuracy: 0.5
        )

        session.setTertiaryPresented(true)

        XCTAssertEqual(ObjectIdentifier(session.panel), panelIdentity)
        XCTAssertTrue(panel.contentViewController === hostingController)
        XCTAssertTrue(session.isTertiaryPresented)
        XCTAssertEqual(session.tertiaryPresentationMode, .column)
        XCTAssertEqual(settingsState.tertiaryPresentationMode, .column)
        XCTAssertEqual(
            panel.frame.size,
            GeekPanelPresentationMetrics.expandedSize(
                for: .network,
                density: .geek,
                includesTertiaryColumn: true
            )
        )
        let threeColumnFrames = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(threeColumnFrames.count, 3)
        XCTAssertTrue(threeColumnFrames.contains { approximatelyEqual($0, overviewFrame) })
        assertPairwiseDisjoint(threeColumnFrames)

        session.setTertiaryPresented(false)

        XCTAssertFalse(session.isTertiaryPresented)
        assertRect(panel.frame, equals: twoColumnFrame)
        XCTAssertEqual(session.visibleAttachedContentFramesForTesting.count, 2)

        session.setGeekSection(.overview)
        assertRect(panel.frame, equals: overviewFrame)
    }

    func testNarrowScreenKeepsOverviewAndSecondaryWhileTertiaryIsUnavailable() throws {
        let screen = try requireScreen()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let panel = makePanel()
        let settingsState = MenuBarPanelSettingsState(
            initialDensity: .geek,
            defaults: fixture.defaults
        )
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            geometryStore: fixture.store,
            panelSettingsState: settingsState
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        let overviewFrame = panel.frame
        let leftSpace: CGFloat = 340
        let narrowVisibleFrame = NSRect(
            x: overviewFrame.minX - leftSpace - 8,
            y: screen.visibleFrame.minY,
            width: leftSpace + overviewFrame.width + 16,
            height: screen.visibleFrame.height
        )

        session.setGeekSection(.network, visibleFrameOverride: narrowVisibleFrame)

        XCTAssertEqual(session.secondaryPresentationMode, .adjacent)
        XCTAssertEqual(settingsState.secondaryPresentationMode, .adjacent)
        XCTAssertEqual(session.tertiaryPresentationMode, .unavailable)
        XCTAssertEqual(settingsState.tertiaryPresentationMode, .unavailable)
        XCTAssertEqual(
            panel.frame.size,
            GeekPanelPresentationMetrics.expandedSize(for: .network, density: .geek)
        )
        let visibleFrames = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(visibleFrames.count, 2)
        XCTAssertTrue(visibleFrames.contains { approximatelyEqual($0, overviewFrame) })
        assertPairwiseDisjoint(visibleFrames)

        session.setGeekSection(.overview)

        XCTAssertEqual(session.secondaryPresentationMode, .adjacent)
        XCTAssertEqual(settingsState.secondaryPresentationMode, .adjacent)
        assertRect(panel.frame, equals: overviewFrame)
    }

    func testSessionConsumesVerticallyStackedCascadeFramesWhenBothSidesAreTooNarrow() throws {
        let screen = try requireScreen()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let panel = makePanel()
        let settingsState = MenuBarPanelSettingsState(
            initialDensity: .geek,
            defaults: fixture.defaults
        )
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            geometryStore: fixture.store,
            panelSettingsState: settingsState
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        let overviewFrame = panel.frame
        let sideSpace: CGFloat = 208
        let belowSpace: CGFloat = 700
        let constrainedVisibleFrame = NSRect(
            x: overviewFrame.minX - sideSpace - 8,
            y: overviewFrame.minY - belowSpace - 8,
            width: overviewFrame.width + (sideSpace + 8) * 2,
            height: overviewFrame.height + belowSpace + 16
        )

        session.setGeekSection(.processor, visibleFrameOverride: constrainedVisibleFrame)

        let frames = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(frames.count, 2)
        let detailFrame = try XCTUnwrap(frames.first)
        XCTAssertTrue(frames.contains { approximatelyEqual($0, overviewFrame) })
        XCTAssertEqual(
            overviewFrame.minY - detailFrame.maxY,
            MiniWindowStyleTokens.cascadeGap,
            accuracy: 0.5
        )
        XCTAssertTrue(constrainedVisibleFrame.insetBy(dx: 8, dy: 8).contains(panel.frame))
        XCTAssertTrue(settingsState.cascadeLayout?.childFrames.contains {
            approximatelyEqual($0, detailFrame)
        } == true)
        assertPairwiseDisjoint(frames)
    }

    func testStoredOriginsAreIgnoredAndEveryDensityStaysAnchoredBelowTheStatusItem() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(
            panel: panel,
            initialDensity: .simple,
            geometryStore: fixture.store
        )
        defer { session.teardown() }

        let anchor = makeAnchor(on: screen)
        for (index, density) in PanelDensity.allCases.enumerated() {
            let storedFrame = manualFrame(
                for: density,
                index: index,
                visibleFrame: screen.visibleFrame
            )
            fixture.store.save(frame: storedFrame, for: density)
        }

        session.show(anchor: anchor, screen: screen, density: .simple)
        for density in PanelDensity.allCases {
            session.selectDensity(density)
            assertRect(
                panel.frame,
                equals: MenuBarPanelPlacement.frame(
                    anchor: anchor,
                    contentSize: density.idealSize,
                    visibleFrame: screen.visibleFrame,
                    backingScaleFactor: screen.backingScaleFactor
                )
            )
            XCTAssertEqual(panel.frame.size, density.idealSize)
            XCTAssertEqual(panel.contentMinSize, density.idealSize)
            XCTAssertEqual(panel.contentMaxSize, density.idealSize)
            XCTAssertTrue(panel.contentViewController != nil)
        }
    }

    func testWindowMovePersistsOriginAndKeepsFixedSizeLimits() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(
            panel: panel,
            initialDensity: .complex,
            geometryStore: fixture.store
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .complex)
        var movedFrame = panel.frame
        movedFrame.origin.x = max(screen.visibleFrame.minX + 16, movedFrame.origin.x - 30)
        movedFrame.origin.y = max(screen.visibleFrame.minY + 16, movedFrame.origin.y - 24)
        panel.setFrame(movedFrame, display: false)
        session.windowDidMove(
            Notification(name: NSWindow.didMoveNotification, object: panel)
        )

        assertRect(fixture.store.storedFrame(for: .complex), equals: panel.frame)
        XCTAssertEqual(panel.frame.size, PanelDensity.complex.idealSize)
        XCTAssertEqual(panel.contentMinSize, PanelDensity.complex.idealSize)
        XCTAssertEqual(panel.contentMaxSize, PanelDensity.complex.idealSize)
        XCTAssertFalse(panel.styleMask.contains(.resizable))
    }

    func testDetailedAndGeekPersistCollapsedFrameWhileDetailIsAttached() throws {
        let screen = try requireScreen()

        try [PanelDensity.complex, .geek].forEach { density in
            let panel = makePanel()
            let fixture = try makeGeometryFixture()
            defer {
                fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
            }
            let session = makeSession(
                panel: panel,
                initialDensity: density,
                geometryStore: fixture.store,
                fixedVisibleFrame: Self.deterministicVisibleFrame,
                presentsPanelOnShow: false
            )
            defer { session.teardown() }

            session.show(
                anchor: makeAnchor(in: Self.deterministicVisibleFrame),
                screen: screen,
                density: density
            )
            session.setGeekSection(.network)
            var movedExpandedFrame = panel.frame
            movedExpandedFrame.origin.x -= 12
            movedExpandedFrame.origin.y -= 8
            panel.setFrame(movedExpandedFrame, display: false)
            session.windowDidMove(
                Notification(name: NSWindow.didMoveNotification, object: panel)
            )

            let stored = try XCTUnwrap(fixture.store.storedFrame(for: density))
            XCTAssertEqual(stored.size, density.idealSize, density.rawValue)
            XCTAssertEqual(
                stored.minX,
                movedExpandedFrame.minX
                    + GeekPanelPresentationMetrics.detailSize(
                        for: .network,
                        density: density
                    ).width
                    + MiniWindowStyleTokens.cascadeGap,
                accuracy: 0.5,
                density.rawValue
            )
            XCTAssertEqual(
                stored.maxY,
                movedExpandedFrame.maxY,
                accuracy: 0.5,
                density.rawValue
            )
            XCTAssertNotEqual(stored.size, movedExpandedFrame.size, density.rawValue)
        }
    }

    func testScreenParameterChangeClampsInsteadOfClosingPanel() async throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(panel: panel, geometryStore: fixture.store)
        defer { session.teardown() }

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .simple)
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let offscreenFrame = NSRect(
            x: bounds.maxX + 2_000,
            y: bounds.maxY + 2_000,
            width: PanelDensity.simple.minimumSize.width,
            height: PanelDensity.simple.minimumSize.height
        )
        panel.setFrame(offscreenFrame, display: false)
        session.windowDidMove(
            Notification(name: NSWindow.didMoveNotification, object: panel)
        )

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        for _ in 0..<50 where !bounds.contains(panel.frame) {
            await Task.yield()
        }

        XCTAssertFalse(session.isTornDown)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(bounds.contains(panel.frame), "Expected \(panel.frame) inside \(bounds)")
        assertRect(fixture.store.storedFrame(for: .simple), equals: panel.frame)
    }

    func testScreenParameterChangeReReadsLiveAnchorAndRecomputesCascadeFallback() async throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let settingsState = MenuBarPanelSettingsState(
            initialDensity: .geek,
            defaults: fixture.defaults
        )
        let anchorProvider = MutableMenuBarAnchorProvider(frame: NSRect(
            x: screen.visibleFrame.maxX - 32,
            y: screen.visibleFrame.maxY - 20,
            width: 24,
            height: 20
        ))
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            geometryStore: fixture.store,
            panelSettingsState: settingsState,
            triggerFrameProvider: { anchorProvider.frame }
        )
        defer { session.teardown() }

        session.show(anchor: anchorProvider.frame, screen: screen, density: .geek)
        session.setGeekSection(.network)

        anchorProvider.frame = NSRect(
            x: screen.visibleFrame.minX + 8,
            y: screen.visibleFrame.maxY - 20,
            width: 24,
            height: 20
        )
        let expectedOverview = MenuBarPanelPlacement.frame(
            anchor: anchorProvider.frame,
            contentSize: PanelDensity.geek.idealSize,
            visibleFrame: screen.visibleFrame,
            backingScaleFactor: screen.backingScaleFactor
        )
        let expectedSecondaryCascade = MenuBarPanelPlacement.cascade(
            parentFrame: expectedOverview,
            childSizes: [GeekPanelPresentationMetrics.detailSize(for: .network, density: .geek)],
            visibleFrame: screen.visibleFrame
        )
        let expectedCompleteCascade = MenuBarPanelPlacement.cascade(
            parentFrame: expectedOverview,
            childSizes: [
                GeekPanelPresentationMetrics.detailSize(for: .network, density: .geek),
                MenuBarPanelPlacement.tertiaryColumnSize,
            ],
            visibleFrame: screen.visibleFrame,
            preferredDirection: expectedSecondaryCascade.direction
        )

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        for _ in 0..<100 where !(fixture.store.storedFrame(for: .geek).map {
            approximatelyEqual($0, expectedOverview)
        } ?? false) {
            await Task.yield()
        }

        XCTAssertEqual(session.geekSection, .network)
        XCTAssertEqual(session.cascadeDirection, expectedSecondaryCascade.direction)
        XCTAssertEqual(
            session.tertiaryPresentationMode,
            expectedCompleteCascade.tertiaryPresentationMode
        )
        XCTAssertEqual(
            settingsState.tertiaryPresentationMode,
            expectedCompleteCascade.tertiaryPresentationMode
        )
        switch expectedSecondaryCascade.direction {
        case .left:
            XCTAssertEqual(panel.frame.maxX, expectedOverview.maxX, accuracy: 0.5)
        case .right:
            XCTAssertEqual(panel.frame.minX, expectedOverview.minX, accuracy: 0.5)
        }
        assertRect(fixture.store.storedFrame(for: .geek), equals: expectedOverview)
    }

    func testApplicationDeactivationClosesPanel() async throws {
        let screen = try requireScreen()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        var dismissCount = 0
        let session = makeSession(
            panel: makePanel(),
            geometryStore: fixture.store,
            onDismiss: { dismissCount += 1 }
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .simple)

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        for _ in 0..<50 where session.isPresented {
            await Task.yield()
        }

        XCTAssertFalse(session.isPresented)
        XCTAssertFalse(session.isTornDown)
        XCTAssertFalse(session.panel.isVisible)
        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(session.activeObserverCount, 0)
    }

    func testVisibleNativeMenuGetsEscapeBeforeThePresentedHierarchy() throws {
        let panel = makePanel()
        let coordinator = GeekPanelCoordinator()
        let session = makeSession(panel: panel, panelCoordinator: coordinator)
        defer { session.teardown() }
        let screen = try requireScreen()
        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        coordinator.selectModule(.processor)
        coordinator.presentHistory(.builtIn("cpu"), pinned: true)
        let route = coordinator.route
        let menu = NSMenu()
        let submenu = NSMenu()
        let escape = try makeKeyEvent(characters: "\u{1B}", keyCode: 53, windowNumber: 0)
        let center = NotificationCenter.default

        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: submenu)
        XCTAssertTrue(session.handleKeyEvent(escape) === escape)
        XCTAssertEqual(panel.onEscape?(), false)
        XCTAssertEqual(coordinator.route, route)
        XCTAssertTrue(session.isPresented)

        center.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        XCTAssertTrue(session.handleKeyEvent(escape) === escape)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)

        XCTAssertNil(session.handleKeyEvent(escape, sourceWindow: panel))
        XCTAssertEqual(coordinator.route, .module(.processor))
        XCTAssertNil(session.handleKeyEvent(escape, sourceWindow: panel))
        XCTAssertEqual(coordinator.route, .summary)
        XCTAssertNil(session.handleKeyEvent(escape, sourceWindow: panel))
        XCTAssertFalse(session.isPresented)
        XCTAssertEqual(session.activeObserverCount, 0)
    }

    func testMenuTrackingDefersDeactivationAndRechecksActivityAtTheEnd() async throws {
        @MainActor final class ApplicationActivity {
            var isActive = false
        }
        let application = ApplicationActivity()
        let session = makeSession(
            panel: makePanel(),
            applicationIsActiveProvider: { application.isActive }
        )
        defer { session.teardown() }
        let screen = try requireScreen()
        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        let menu = NSMenu()
        let center = NotificationCenter.default

        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertTrue(session.isPresented)
        application.isActive = true
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(session.isPresented)

        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        application.isActive = false
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertTrue(session.isPresented)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        let didClose = await eventually { !session.isPresented }
        XCTAssertTrue(didClose, "A genuine application switch must still close the panel")
        XCTAssertEqual(session.activeObserverCount, 0)
    }

    func testNativeMenuUnknownMouseSourceDoesNotDismissButLaterOutsideClickDoes() throws {
        let panel = makePanel()
        let session = makeSession(panel: panel)
        defer { session.teardown() }
        let screen = try requireScreen()
        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        let menu = NSMenu()
        let outside = NSPoint(x: panel.frame.minX - 20, y: panel.frame.minY - 20)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertFalse(session.handleMouseDown(sourceWindow: nil, screenLocation: outside))
        XCTAssertTrue(session.isPresented)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertTrue(session.handleMouseDown(sourceWindow: nil, screenLocation: outside))
        XCTAssertFalse(session.isPresented)
    }

    func testMouseDownKeepsPanelFamilyAndAnchorButClosesForUnrelatedWindow() throws {
        let screen = try requireScreen()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let panel = makePanel()
        let anchor = makeAnchor(on: screen)
        var triggerFrame = anchor
        let session = makeSession(
            panel: panel,
            geometryStore: fixture.store,
            triggerFrameProvider: { triggerFrame }
        )
        defer { session.teardown() }

        session.show(anchor: anchor, screen: screen, density: .simple)
        XCTAssertFalse(session.handleMouseDown(
            sourceWindow: panel,
            screenLocation: NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        ))

        let child = makePanel()
        let grandchild = makePanel()
        panel.addChildWindow(child, ordered: .above)
        child.addChildWindow(grandchild, ordered: .above)
        defer {
            child.removeChildWindow(grandchild)
            grandchild.close()
            panel.removeChildWindow(child)
            child.close()
        }
        XCTAssertFalse(session.handleMouseDown(
            sourceWindow: grandchild,
            screenLocation: NSPoint(x: panel.frame.maxX + 20, y: panel.frame.maxY + 20)
        ))

        triggerFrame = anchor.offsetBy(dx: 80, dy: 0)
        XCTAssertFalse(session.handleMouseDown(
            sourceWindow: nil,
            screenLocation: NSPoint(x: triggerFrame.midX, y: triggerFrame.midY)
        ))
        XCTAssertFalse(session.handleMouseDown(
            sourceWindow: nil,
            screenLocation: NSPoint(x: panel.frame.maxX + 20, y: panel.frame.maxY + 20),
            eventWindowNumber: 0
        ))

        let menuWindow = makePanel()
        menuWindow.level = .popUpMenu
        XCTAssertFalse(session.handleMouseDown(
            sourceWindow: menuWindow,
            screenLocation: NSPoint(x: panel.frame.maxX + 20, y: panel.frame.maxY + 20)
        ))
        menuWindow.close()

        let unrelatedWindow = makePanel()
        defer { unrelatedWindow.close() }
        XCTAssertTrue(session.handleMouseDown(
            sourceWindow: unrelatedWindow,
            screenLocation: NSPoint(x: panel.frame.maxX + 20, y: panel.frame.maxY + 20)
        ))
        XCTAssertFalse(session.isPresented)
        XCTAssertFalse(session.isTornDown)
    }

    func testGlobalMouseDownOutsideClosesPanel() throws {
        let screen = try requireScreen()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(panel: makePanel(), geometryStore: fixture.store)
        defer { session.teardown() }
        let anchor = makeAnchor(on: screen)

        session.show(anchor: anchor, screen: screen, density: .simple)
        XCTAssertFalse(session.handleMouseDown(
            sourceWindow: nil,
            screenLocation: NSPoint(x: anchor.midX, y: anchor.midY)
        ))
        XCTAssertTrue(session.handleMouseDown(
            sourceWindow: nil,
            screenLocation: NSPoint(x: session.panel.frame.minX - 20, y: session.panel.frame.minY - 20)
        ))
        XCTAssertFalse(session.isPresented)
        XCTAssertFalse(session.isTornDown)
    }

    func testDetailedAndGeekAttachedTransparentCornerClosesLikeAnOutsideClick() throws {
        let screen = try requireScreen()

        try [PanelDensity.complex, .geek].forEach { density in
            let fixture = try makeGeometryFixture()
            defer {
                fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
            }
            let panel = makePanel()
            let session = makeSession(
                panel: panel,
                initialDensity: density,
                geometryStore: fixture.store,
                fixedVisibleFrame: Self.deterministicVisibleFrame,
                presentsPanelOnShow: false
            )
            defer { session.teardown() }

            session.show(
                anchor: makeAnchor(in: Self.deterministicVisibleFrame),
                screen: screen,
                density: density
            )
            session.setGeekSection(.disk)

            XCTAssertFalse(session.handleMouseDown(
                sourceWindow: panel,
                screenLocation: NSPoint(x: panel.frame.maxX - 10, y: panel.frame.maxY - 10)
            ), density.rawValue)

            let detailFrame = try XCTUnwrap(
                session.visibleAttachedContentFramesForTesting.first
            )
            XCTAssertFalse(session.handleMouseDown(
                sourceWindow: panel,
                screenLocation: NSPoint(x: detailFrame.midX, y: detailFrame.midY)
            ), density.rawValue)

            XCTAssertTrue(session.handleMouseDown(
                sourceWindow: panel,
                screenLocation: NSPoint(x: panel.frame.minX + 10, y: panel.frame.maxY - 10)
            ), density.rawValue)
            XCTAssertFalse(session.isPresented, density.rawValue)
            XCTAssertFalse(session.isTornDown, density.rawValue)
        }
    }

    func testNetworkSecondarySurfaceSharesThePrimaryTopContourWithoutMoving() throws {
        let screen = try requireScreen()

        try [PanelDensity.complex, .geek].forEach { density in
            let fixture = try makeGeometryFixture()
            defer {
                fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
            }
            let panel = makePanel()
            let session = makeSession(
                panel: panel,
                initialDensity: density,
                geometryStore: fixture.store
            )
            defer { session.teardown() }

            session.show(anchor: makeAnchor(on: screen), screen: screen, density: density)
            session.setGeekSection(.network)

            XCTAssertEqual(
                GeekPanelPresentationMetrics.detailVerticalOffset(
                    for: .network,
                    density: density
                ),
                0
            )
            let frames = session.visibleAttachedContentFramesForTesting
            XCTAssertEqual(frames.count, 2)
            XCTAssertEqual(frames[0].maxY, frames[1].maxY, accuracy: 0.001)
            XCTAssertFalse(session.handleMouseDown(
                sourceWindow: panel,
                screenLocation: NSPoint(x: frames[0].minX + 10, y: frames[0].maxY - 10)
            ))
            XCTAssertFalse(session.isTornDown)
        }
    }

    func testNativePointerTrackingKeepsCascadeConnectorsInsideTheHoverEnvelope() throws {
        XCTAssertEqual(MiniWindowStyleTokens.cascadeGap, 0)
        let screen = try requireScreen()
        let panel = makePanel()
        let coordinator = GeekPanelCoordinator()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            geometryStore: fixture.store,
            panelCoordinator: coordinator
        )
        defer { session.teardown() }

        let contentView = try XCTUnwrap(panel.contentView)
        let trackingContainer = try XCTUnwrap(contentView.superview)
        let trackingView = trackingContainer.subviews.first {
            String(describing: type(of: $0)).contains("MenuBarPanelPointerTrackingView")
        }
        XCTAssertNotNil(trackingView)
        XCTAssertTrue(trackingView?.superview === trackingContainer)
        XCTAssertFalse(trackingView?.superview === contentView)

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        session.setGeekSection(.network)

        let frames = session.visibleAttachedContentFramesForTesting.sorted { $0.minX < $1.minX }
        XCTAssertEqual(frames.count, 2)

        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(
                right.minX - left.maxX,
                MiniWindowStyleTokens.cascadeGap,
                accuracy: 0.001
            )
            let lowerBound = max(left.minY, right.minY)
            let upperBound = min(left.maxY, right.maxY)
            let connector = NSPoint(
                x: left.maxX + MiniWindowStyleTokens.cascadeGap / 2,
                y: (lowerBound + upperBound) / 2
            )

            panel.onPointerLocationChanged?(connector)
            XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope)
        }

        let left = try XCTUnwrap(frames.first)
        let right = try XCTUnwrap(frames.dropFirst().first)
        panel.onPointerLocationChanged?(NSPoint(
            x: left.maxX + MiniWindowStyleTokens.cascadeGap / 2,
            y: max(left.maxY, right.maxY) + 8
        ))
        XCTAssertFalse(coordinator.isPointerWithinHoverEnvelope)
    }

    func testPointerCanMoveAcrossTheJoinedEdgeIntoDetail() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let coordinator = GeekPanelCoordinator()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            geometryStore: fixture.store,
            panelCoordinator: coordinator
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        session.setGeekSection(.processor)

        let frames = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(frames.count, 2)
        let detail = frames[0]
        let overview = frames[1]
        XCTAssertEqual(overview.maxY, detail.maxY, accuracy: 0.001)

        let origin = NSPoint(
            x: detail.maxX <= overview.minX ? overview.minX + 40 : overview.maxX - 40,
            y: overview.minY + min(overview.height, detail.height) / 2
        )
        let destinationEdgeX = detail.maxX <= overview.minX ? detail.maxX : detail.minX
        let safeX = (destinationEdgeX + (detail.maxX <= overview.minX ? overview.minX : overview.maxX)) / 2
        let safePoint = NSPoint(
            x: safeX,
            y: origin.y
        )

        XCTAssertEqual(abs(detail.maxX <= overview.minX ? detail.maxX - overview.minX : detail.minX - overview.maxX), 0, accuracy: 0.001)
        panel.onPointerLocationChanged?(origin)
        panel.onPointerLocationChanged?(safePoint)
        XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope)

        panel.onPointerLocationChanged?(NSPoint(x: safePoint.x, y: max(overview.maxY, detail.maxY) + 20))
        XCTAssertFalse(coordinator.isPointerWithinHoverEnvelope)
    }

    func testCascadeGeometryRefreshesHoverEnvelopeWithoutWaitingForMouseEvent() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let coordinator = GeekPanelCoordinator()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let pointerLocation = PointerLocationBox(NSPoint(
            x: screen.visibleFrame.minX - 20,
            y: screen.visibleFrame.minY - 20
        ))
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            geometryStore: fixture.store,
            panelCoordinator: coordinator,
            pointerLocationProvider: { pointerLocation.value }
        )
        defer { session.teardown() }

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        session.setGeekSection(.network)

        let twoColumnFrames = session.visibleAttachedContentFramesForTesting
            .sorted { $0.minX < $1.minX }
        XCTAssertEqual(twoColumnFrames.count, 2)
        let secondaryFrame = session.cascadeDirection == .left
            ? twoColumnFrames[0]
            : twoColumnFrames[1]
        let secondaryPoint = NSPoint(x: secondaryFrame.midX, y: secondaryFrame.midY)

        session.setGeekSection(.overview)
        XCTAssertFalse(coordinator.isPointerWithinHoverEnvelope)

        // No `panel.onPointerLocationChanged` call follows. Re-expanding must
        // still sample the current pointer before a hover-dismiss can run.
        pointerLocation.value = secondaryPoint
        session.setGeekSection(.network)
        XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope)

        session.setTertiaryPresented(true)
        let threeColumnFrames = session.visibleAttachedContentFramesForTesting
            .sorted { $0.minX < $1.minX }
        guard threeColumnFrames.count == 3 else {
            XCTAssertFalse(session.isTertiaryPresented)
            return
        }
        let tertiaryFrame = session.cascadeDirection == .left
            ? threeColumnFrames[0]
            : threeColumnFrames[2]
        let tertiaryPoint = NSPoint(x: tertiaryFrame.midX, y: tertiaryFrame.midY)

        pointerLocation.value = NSPoint(
            x: screen.visibleFrame.minX - 20,
            y: screen.visibleFrame.minY - 20
        )
        session.setTertiaryPresented(false)
        XCTAssertFalse(coordinator.isPointerWithinHoverEnvelope)

        pointerLocation.value = tertiaryPoint
        session.setTertiaryPresented(true)
        XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope)
    }

    func testGeekEditorIsPresentedAsPopoverWithoutResizingSession() throws {
        let chromeSource = try projectSource(
            "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"
        )
        let controllerSource = try projectSource(
            "Sources/StorageCleanerMac/Support/MenuBarStatusController.swift"
        )

        XCTAssertTrue(chromeSource.contains(
            ".popover(isPresented: geekEditorBinding, arrowEdge: .trailing)"
        ))
        XCTAssertTrue(chromeSource.contains("GeekDashboardEditor(state: state)"))
        XCTAssertFalse(chromeSource.contains("resize(contentSize:"))
        XCTAssertFalse(controllerSource.contains("setPanelSettingsPresented"))
    }

    func testShowInstallsPersistentPanelHandlersOnceAndTeardownRemovesThem() throws {
        let screen = try requireScreen()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let panel = makePanel()
        let session = makeSession(panel: panel, geometryStore: fixture.store)
        let anchor = makeAnchor(on: screen)

        session.show(anchor: anchor, screen: screen, density: .simple)
        XCTAssertEqual(session.activeMonitorCount, 3)
        XCTAssertEqual(session.activeObserverCount, 4)
        XCTAssertTrue(panel.acceptsMouseMovedEvents)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertNotNil(panel.onPointerLocationChanged)

        session.show(anchor: anchor, screen: screen, density: .simple)
        XCTAssertEqual(session.activeMonitorCount, 3)
        XCTAssertEqual(session.activeObserverCount, 4)

        session.teardown()
        XCTAssertEqual(session.activeMonitorCount, 0)
        XCTAssertEqual(session.activeObserverCount, 0)
        XCTAssertNil(panel.onPointerLocationChanged)
    }

    func testHideAndShowThirtyTimesReusePanelAndHostingControllerWithoutHandlerGrowth() throws {
        let screen = try requireScreen()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let panel = makePanel()
        let session = makeSession(panel: panel, geometryStore: fixture.store)
        defer { session.teardown() }
        let anchor = makeAnchor(on: screen)

        session.show(anchor: anchor, screen: screen, density: .geek)
        let hostingController = try XCTUnwrap(
            panel.contentViewController as? NSHostingController<AnyView>
        )

        for _ in 0..<30 {
            session.hide()
            XCTAssertFalse(session.isPresented)
            XCTAssertFalse(session.isTornDown)
            XCTAssertEqual(session.activeMonitorCount, 0)
            XCTAssertEqual(session.activeObserverCount, 0)

            session.show(anchor: anchor, screen: screen, density: .geek)
            XCTAssertTrue(session.isPresented)
            XCTAssertTrue(panel.contentViewController === hostingController)
            XCTAssertEqual(hostingController.view.bounds.size, panel.contentLayoutRect.size)
            XCTAssertTrue(panel.contentView === hostingController.view)
            XCTAssertEqual(session.activeMonitorCount, 3)
            XCTAssertEqual(session.activeObserverCount, 4)
        }
    }

    func testOneHundredSecondaryOpenCloseCyclesReusePanelAndHandlers() throws {
        let screen = try requireScreen()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let panel = makePanel()
        let coordinator = GeekPanelCoordinator()
        let session = makeSession(
            panel: panel,
            geometryStore: fixture.store,
            panelCoordinator: coordinator
        )
        defer { session.teardown() }
        let anchor = makeAnchor(on: screen)

        session.show(anchor: anchor, screen: screen, density: .geek)
        let hostingController = try XCTUnwrap(
            panel.contentViewController as? NSHostingController<AnyView>
        )
        let overviewWidth = panel.frame.width

        for _ in 0..<100 {
            coordinator.previewModule(.processor)
            session.setGeekSection(.processor)
            XCTAssertGreaterThan(panel.frame.width, overviewWidth)

            coordinator.reset()
            session.setGeekSection(.overview)
            XCTAssertEqual(panel.frame.width, overviewWidth, accuracy: 0.5)
            XCTAssertTrue(panel.contentViewController === hostingController)
            XCTAssertEqual(session.activeMonitorCount, 3)
            XCTAssertEqual(session.activeObserverCount, 4)
        }
    }

    func testTeardownIsIdempotentAndCallsOnCloseOnce() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        var closeCount = 0
        let session = makeSession(
            panel: panel,
            geometryStore: fixture.store,
            onClose: { closeCount += 1 }
        )

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .simple)
        XCTAssertNotNil(panel.contentViewController)
        XCTAssertTrue(panel.isVisible)

        session.teardown()
        session.teardown()

        XCTAssertTrue(session.isTornDown)
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.contentViewController)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(session.activeMonitorCount, 0)
        XCTAssertEqual(session.activeObserverCount, 0)
    }

    func testIdlePanelReclamationOnlyTargetsHiddenLiveSession() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let fixture = try makeGeometryFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let session = makeSession(panel: panel, geometryStore: fixture.store)

        XCTAssertTrue(MenuBarPanelIdleReclamationPolicy.shouldReclaim(session))
        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)
        XCTAssertFalse(MenuBarPanelIdleReclamationPolicy.shouldReclaim(session))
        session.hide()
        XCTAssertTrue(MenuBarPanelIdleReclamationPolicy.shouldReclaim(session))
        session.teardown()
        XCTAssertFalse(MenuBarPanelIdleReclamationPolicy.shouldReclaim(session))
        XCTAssertFalse(MenuBarPanelIdleReclamationPolicy.shouldReclaim(nil))
    }

    func testEscapeClosesPanelWhileOtherKeysPassThrough() throws {
        let panel = makePanel()
        let session = makeSession(panel: panel)
        let regularEvent = try makeKeyEvent(
            characters: "a",
            keyCode: 0
        )
        defer { session.teardown() }

        XCTAssertTrue(session.handleKeyEvent(regularEvent) === regularEvent)
        XCTAssertFalse(session.isTornDown)

        let unrelatedWindow = makePanel()
        let unrelatedEscape = try makeKeyEvent(
            characters: "\u{1B}",
            keyCode: 53
        )
        XCTAssertTrue(
            session.handleKeyEvent(unrelatedEscape, sourceWindow: unrelatedWindow) === unrelatedEscape
        )
        XCTAssertFalse(session.isTornDown)
        unrelatedWindow.close()

        let menuTrackingEscape = try makeKeyEvent(
            characters: "\u{1B}",
            keyCode: 53,
            windowNumber: 0
        )
        XCTAssertTrue(session.handleKeyEvent(menuTrackingEscape) === menuTrackingEscape)
        XCTAssertFalse(session.isTornDown)

        let panelEscape = try makeKeyEvent(
            characters: "\u{1B}",
            keyCode: 53
        )
        XCTAssertNil(session.handleKeyEvent(panelEscape, sourceWindow: panel))
        XCTAssertFalse(session.isPresented)
        XCTAssertFalse(session.isTornDown)
    }

    func testEscapeFromAnotherAppWindowClosesPresentedPanel() throws {
        let screen = try requireScreen()
        let panel = makePanel()
        let session = makeSession(panel: panel, presentsPanelOnShow: false)
        let appWindow = makePanel()
        let escape = try makeKeyEvent(characters: "\u{1B}", keyCode: 53)
        defer {
            appWindow.close()
            session.teardown()
        }

        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .simple)

        XCTAssertNil(session.handleKeyEvent(escape, sourceWindow: appWindow))
        XCTAssertFalse(session.isPresented)
    }

    func testNonactivatingPanelDispatchesEscapeThroughTheSharedRoute() throws {
        let panel = makePanel()
        let coordinator = GeekPanelCoordinator()
        let session = makeSession(panel: panel, panelCoordinator: coordinator)
        let escape = try makeKeyEvent(characters: "\u{1B}", keyCode: 53)
        defer { session.teardown() }

        coordinator.selectModule(.sensors)
        panel.sendEvent(escape)

        XCTAssertEqual(coordinator.route, .summary)
        XCTAssertFalse(session.isTornDown)
    }

    func testGeekCoordinatorPinsClicksAndEscapeClosesDeepestRouteFirst() throws {
        let panel = makePanel()
        let coordinator = GeekPanelCoordinator()
        let session = makeSession(
            panel: panel,
            initialDensity: .geek,
            panelCoordinator: coordinator
        )
        defer { session.teardown() }
        let screen = try requireScreen()
        session.show(anchor: makeAnchor(on: screen), screen: screen, density: .geek)

        coordinator.previewModule(.processor)
        XCTAssertEqual(coordinator.route, .module(.processor))
        XCTAssertFalse(coordinator.isModulePinned)
        coordinator.dismissUnpinnedModule()
        XCTAssertEqual(coordinator.route, .summary)

        coordinator.previewModule(.memory)
        coordinator.selectModule(.memory)
        coordinator.dismissUnpinnedModule()
        XCTAssertEqual(coordinator.route, .module(.memory))
        XCTAssertTrue(coordinator.isModulePinned)

        coordinator.presentHistory(.builtIn("memory"), pinned: true)
        XCTAssertEqual(
            coordinator.route,
            .history(module: .memory, selection: .builtIn("memory"))
        )

        let escape = try makeKeyEvent(characters: "\u{1B}", keyCode: 53)
        XCTAssertNil(session.handleKeyEvent(escape, sourceWindow: panel))
        XCTAssertEqual(coordinator.route, .module(.memory))
        XCTAssertFalse(session.isTornDown)

        XCTAssertNil(session.handleKeyEvent(escape, sourceWindow: panel))
        XCTAssertEqual(coordinator.route, .summary)
        XCTAssertFalse(session.isTornDown)

        XCTAssertNil(session.handleKeyEvent(escape, sourceWindow: panel))
        XCTAssertFalse(session.isPresented)
        XCTAssertFalse(session.isTornDown)
    }

    func testScreenChangeUsesOnlyCurrentlyAttachedScreens() throws {
        let source = try projectSource(
            "Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift"
        )

        XCTAssertTrue(source.contains("let currentScreens = NSScreen.screens"))
        XCTAssertTrue(source.contains("let liveAnchor = triggerFrameProvider?() ?? previousAnchor"))
        XCTAssertTrue(source.contains("let anchorScreen = currentScreens.first"))
        XCTAssertTrue(source.contains("setGeekSection(sectionToRestore)"))
        XCTAssertTrue(source.contains("currentScreens.first(where: { $0 === candidate })"))
        XCTAssertTrue(source.contains("ScreenContextResolver.resolve("))
        XCTAssertTrue(source.contains("statusItemScreen: anchorScreen"))
        XCTAssertTrue(source.contains("fallbackScreen: currentPanelScreen ?? intersectingScreen"))
    }

    private func makeSession(
        panel: MenuBarStatusPanel,
        initialDensity: PanelDensity = .simple,
        initialOverviewSize: CGSize? = nil,
        geometryStore: PanelGeometryStore = PanelGeometryStore(),
        panelSettingsState: MenuBarPanelSettingsState? = nil,
        panelCoordinator: GeekPanelCoordinator? = nil,
        controlPaletteCoordinator: ControlPaletteCoordinator? = nil,
        triggerFrameProvider: (@MainActor () -> NSRect?)? = nil,
        pointerLocationProvider: @escaping @MainActor () -> NSPoint = {
            NSEvent.mouseLocation
        },
        applicationIsActiveProvider: @escaping @MainActor () -> Bool = { NSApp.isActive },
        fixedVisibleFrame: NSRect? = nil,
        presentsPanelOnShow: Bool = true,
        onClose: @escaping @MainActor () -> Void = {},
        onDismiss: @escaping @MainActor () -> Void = {}
    ) -> MenuBarPanelSession {
        MenuBarPanelSession(
            panel: panel,
            rootView: AnyView(EmptyView()),
            initialDensity: initialDensity,
            initialOverviewSize: initialOverviewSize,
            geometryStore: geometryStore,
            panelSettingsState: panelSettingsState,
            panelCoordinator: panelCoordinator,
            controlPaletteCoordinator: controlPaletteCoordinator,
            triggerFrameProvider: triggerFrameProvider,
            pointerLocationProvider: pointerLocationProvider,
            applicationIsActiveProvider: applicationIsActiveProvider,
            fixedVisibleFrame: fixedVisibleFrame,
            presentsPanelOnShow: presentsPanelOnShow,
            onClose: onClose,
            onDismiss: onDismiss
        )
    }

    private func makePanel() -> MenuBarStatusPanel {
        let panel = MenuBarStatusPanel(contentRect: .zero)
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func makeGeometryFixture() throws -> (
        store: PanelGeometryStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "MenuBarPanelSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (PanelGeometryStore(defaults: defaults), defaults, suiteName)
    }

    private func manualFrame(
        for density: PanelDensity,
        index: Int,
        visibleFrame: NSRect
    ) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(density.minimumSize.width + CGFloat(index * 24), bounds.width)
        let height = min(density.minimumSize.height + CGFloat(index * 18), bounds.height)
        let availableX = max(0, bounds.width - width)
        let availableY = max(0, bounds.height - height)
        return NSRect(
            x: bounds.minX + min(CGFloat(24 + index * 28), availableX),
            y: bounds.minY + min(CGFloat(20 + index * 22), availableY),
            width: width,
            height: height
        )
    }

    private func assertRect(
        _ actual: NSRect?,
        equals expected: NSRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("Expected a persisted frame", file: file, line: line)
            return
        }
        // AppKit snaps borderless window origins to backing pixels; an odd
        // fixed width can therefore differ from the ideal centered frame by
        // half a point on a 1x coordinate grid.
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }

    private func approximatelyEqual(_ first: NSRect, _ second: NSRect) -> Bool {
        abs(first.minX - second.minX) <= 0.5
            && abs(first.minY - second.minY) <= 0.5
            && abs(first.width - second.width) <= 0.001
            && abs(first.height - second.height) <= 0.001
    }

    private func assertPairwiseDisjoint(
        _ frames: [NSRect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
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

    private func requireScreen() throws -> NSScreen {
        try XCTUnwrap(NSScreen.screens.first, "Tests require an attached screen")
    }

    private func eventually(
        attempts: Int = 100,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeAnchor(on screen: NSScreen) -> NSRect {
        makeAnchor(in: screen.visibleFrame)
    }

    private func makeAnchor(in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.midX - 12,
            y: visibleFrame.maxY - 24,
            width: 24,
            height: 20
        )
    }

    private func makeKeyEvent(
        characters: String,
        keyCode: UInt16,
        windowNumber: Int = 0
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private func projectSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

@MainActor
private final class MutableMenuBarAnchorProvider {
    var frame: NSRect

    init(frame: NSRect) {
        self.frame = frame
    }
}
