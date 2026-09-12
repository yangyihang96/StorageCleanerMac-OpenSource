import AppKit
import XCTest
@testable import StorageCleanerMac

final class WindowGlassConfigurationTests: XCTestCase {
    #if DEBUG || STORAGE_CLEANER_BETA
    @MainActor
    func testMainWindowGoldenCaptureUsesReferenceAspectRatio() {
        let size = MainWindowSnapshotPipeline.goldenReferenceContentSize
        XCTAssertEqual(size.width / size.height, 1_624.0 / 969.0, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(size.width, AppWindowLayoutPolicy.referenceContentSize.width)
        XCTAssertGreaterThanOrEqual(size.height, AppWindowLayoutPolicy.referenceContentSize.height)
    }
    #endif

    @MainActor
    func testWindowConfigurationViewCoalescesRepeatedSwiftUIUpdates() {
        let configured = expectation(description: "window configured once")
        var callbackCount = 0

        let view = PassthroughWindowConfigurationView { _ in
            callbackCount += 1
            configured.fulfill()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        window.contentView = view
        view.updateConfiguration { _ in
            callbackCount += 1
            configured.fulfill()
        }
        view.updateConfiguration { _ in
            callbackCount += 1
            configured.fulfill()
        }

        wait(for: [configured], timeout: 1)
        XCTAssertEqual(callbackCount, 1)
    }

    func testWindowConfiguratorsPreserveNativeChromeAndRestoredPlacement() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let glassSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Support/GlassStyle.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let mainChromeSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/ModulePresentation.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(mainChromeSource.contains("struct MainWindowChromeConfigurator: NSViewRepresentable"))
        XCTAssertTrue(mainChromeSource.contains("window.titleVisibility = .hidden"))
        XCTAssertTrue(mainChromeSource.contains("window.titlebarAppearsTransparent = true"))
        XCTAssertTrue(mainChromeSource.contains("window.styleMask.insert(.fullSizeContentView)"))
        XCTAssertTrue(mainChromeSource.contains("window.titlebarSeparatorStyle = .none"))
        XCTAssertFalse(mainChromeSource.contains("window.toolbar = nil"))
        XCTAssertTrue(mainChromeSource.contains("AppWindowLayoutPolicy.referenceContentSize"))
        XCTAssertFalse(mainChromeSource.contains("window.contentAspectRatio"))
        XCTAssertTrue(mainChromeSource.contains("window.contentMinSize"))
        XCTAssertTrue(mainChromeSource.contains("window.contentMaxSize"))
        XCTAssertTrue(mainChromeSource.contains("NSWindow.willEnterFullScreenNotification"))
        XCTAssertTrue(mainChromeSource.contains("NSWindow.didExitFullScreenNotification"))
        XCTAssertTrue(mainChromeSource.contains("AppWindowLayoutPolicy.unboundedContentSize"))
        XCTAssertTrue(mainChromeSource.contains("window.setFrame(targetFrame"))
        XCTAssertTrue(mainChromeSource.contains("NSWindow.didChangeScreenNotification"))
        XCTAssertTrue(mainChromeSource.contains("NSApplication.didChangeScreenParametersNotification"))
        XCTAssertFalse(mainChromeSource.contains("standardWindowButton"))

        XCTAssertFalse(glassSource.contains("titlebarAppearsTransparent"))
        XCTAssertFalse(glassSource.contains("fullSizeContentView"))
        XCTAssertFalse(glassSource.contains("didPlaceMainWindow"))
        XCTAssertFalse(glassSource.contains("window.setFrame"))
        XCTAssertTrue(glassSource.contains("configurationIsScheduled"))
        XCTAssertTrue(settingsSource.contains("let minimumSize = NSSize(width: 720, height: 500)"))
        XCTAssertTrue(settingsSource.contains("let maximumSize = NSSize(width: 820"))
        XCTAssertTrue(settingsSource.contains("let compactWidth: CGFloat = 780"))
        XCTAssertTrue(settingsSource.contains("SettingsWindowPlacement.requiresRestoration("))
        XCTAssertFalse(settingsSource.contains("didPlaceWindow"))
        XCTAssertFalse(settingsSource.contains("targetSize"))
        XCTAssertFalse(settingsSource.contains("visibleFrame.midX"))
        XCTAssertFalse(glassSource.contains("func updateNSView(_ view: NSView, context: Context) {\n        DispatchQueue.main.async"))
        XCTAssertFalse(settingsSource.contains("func updateNSView(_ view: NSView, context: Context) {\n        DispatchQueue.main.async"))
    }

    func testMainWindowMaximumUsesTheAvailableDisplayAreaAtEveryDockPosition() {
        let visibleFrames = [
            NSRect(x: 0, y: 0, width: 1_280, height: 800),
            NSRect(x: 0, y: 0, width: 1_440, height: 900),
            NSRect(x: 0, y: 0, width: 1_512, height: 982),
            NSRect(x: 0, y: 0, width: 1_728, height: 1_117),
            NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
            NSRect(x: 0, y: 70, width: 1_280, height: 730),
            NSRect(x: 72, y: 0, width: 1_208, height: 800),
            NSRect(x: 0, y: 0, width: 1_208, height: 800),
            NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
        ]

        for visibleFrame in visibleFrames {
            let available = AppWindowLayoutPolicy.availableFrame(in: visibleFrame)
            let size = AppWindowLayoutPolicy.maximumContentSize(in: visibleFrame)
            let origin = AppWindowLayoutPolicy.centeredOrigin(for: size, in: visibleFrame)
            let frame = NSRect(origin: origin, size: size)

            XCTAssertLessThanOrEqual(size.width, available.width + 0.001)
            XCTAssertLessThanOrEqual(size.height, available.height + 0.001)
            XCTAssertEqual(size.width, available.width, accuracy: 0.000_001)
            XCTAssertEqual(size.height, available.height, accuracy: 0.000_001)
            XCTAssertTrue(available.contains(frame), "visibleFrame=\(visibleFrame) frame=\(frame)")
        }
    }

    func testMainWindowClampsEachDimensionAndAllowsLargeDisplayExpansion() {
        let small = NSRect(x: 0, y: 0, width: 900, height: 620)
        let large = NSRect(x: 0, y: 0, width: 3_840, height: 2_160)
        let smallSize = AppWindowLayoutPolicy.fittedContentSize(
            NSSize(width: 1_600, height: 1_200),
            in: small
        )
        let largeSize = AppWindowLayoutPolicy.maximumContentSize(in: large)

        XCTAssertLessThan(smallSize.width, AppWindowLayoutPolicy.referenceContentSize.width)
        XCTAssertLessThan(smallSize.height, AppWindowLayoutPolicy.referenceContentSize.height)
        XCTAssertGreaterThan(largeSize.width, AppWindowLayoutPolicy.referenceContentSize.width)
        XCTAssertGreaterThan(largeSize.height, AppWindowLayoutPolicy.referenceContentSize.height)

        let independentlyResized = AppWindowLayoutPolicy.fittedContentSize(
            NSSize(width: 1_400, height: 760),
            in: large
        )
        XCTAssertEqual(independentlyResized, NSSize(width: 1_400, height: 760))
    }

    func testMainWindowClampsInvalidSavedOriginInsideCurrentVisibleFrame() {
        let visible = NSRect(x: 80, y: 40, width: 1_200, height: 720)
        let size = AppWindowLayoutPolicy.maximumContentSize(in: visible)
        let origin = AppWindowLayoutPolicy.clampedOrigin(
            NSPoint(x: 2_000, y: -500),
            size: size,
            in: visible
        )
        let frame = NSRect(origin: origin, size: size)

        XCTAssertTrue(AppWindowLayoutPolicy.isFullyVisible(frame, in: visible))
    }

    func testWindowLayoutMetricsKeepsReadableCompactValues() {
        let compact = WindowLayoutMetrics(contentSize: CGSize(width: 840, height: 550))
        let regular = WindowLayoutMetrics(contentSize: CGSize(width: 980, height: 640))

        XCTAssertEqual(compact.density, .compact)
        XCTAssertEqual(regular.density, .regular)
        XCTAssertTrue(compact.isShort)
        XCTAssertFalse(regular.isShort)
        XCTAssertGreaterThanOrEqual(compact.rowHeight, AppControlSizes.minimumControlHeight)
        XCTAssertLessThan(compact.sidebarIdealWidth, regular.sidebarIdealWidth)
        XCTAssertLessThan(compact.contentPadding, regular.contentPadding)
    }

    func testSettingsWindowPlacementLeavesVisibleFrameUnchanged() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 200, y: 120, width: 700, height: 620)

        XCTAssertFalse(SettingsWindowPlacement.requiresRestoration(frame, within: [visible]))
        XCTAssertEqual(SettingsWindowPlacement.clamped(frame, to: visible), frame)
    }

    func testSettingsWindowPlacementPreservesPartiallyVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 1300, y: -80, width: 700, height: 620)

        XCTAssertFalse(SettingsWindowPlacement.requiresRestoration(frame, within: [visible]))
    }

    func testSettingsWindowPlacementClampsNearlyOffscreenFrameWithoutRecentering() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: 1380, y: -80, width: 700, height: 620)

        XCTAssertTrue(SettingsWindowPlacement.requiresRestoration(frame, within: [visible]))
        XCTAssertEqual(
            SettingsWindowPlacement.clamped(frame, to: visible),
            NSRect(x: 740, y: 0, width: 700, height: 620)
        )
    }

    func testSettingsWindowPlacementFitsFrameAfterDisplayRemoval() {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 600)
        let frame = NSRect(x: 1600, y: 100, width: 1000, height: 700)

        XCTAssertTrue(SettingsWindowPlacement.requiresRestoration(frame, within: [visible]))
        XCTAssertEqual(SettingsWindowPlacement.clamped(frame, to: visible), visible)
    }

    func testSettingsWindowPlacementPreservesCrossDisplayWindow() {
        let left = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let right = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: 1260, y: 180, width: 700, height: 620)

        XCTAssertFalse(
            SettingsWindowPlacement.requiresRestoration(frame, within: [left, right])
        )
    }
}
