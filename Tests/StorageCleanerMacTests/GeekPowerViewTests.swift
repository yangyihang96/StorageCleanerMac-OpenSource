import AppKit
import XCTest
@testable import StorageCleanerMac

final class GeekPowerViewTests: XCTestCase {
    func testEnergyModeCardUsesHoverAttachedControlPalette() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try r2ProductionSource(at: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift"
            ))
        let card = try sourceSegment(
            source,
            from: "private var geekPowerModeCard",
            to: "func changeEnergyMode"
        )

        XCTAssertTrue(card.contains("ControlPaletteHoverAnchor("))
        XCTAssertTrue(card.contains("kind: .power"))
        XCTAssertFalse(card.contains("ControlPaletteAnchorButton("))
    }

    func testEnergyAppFallbackUsesSharedValidSystemSymbol() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // GeekPowerView hosts the only remaining energy-app row; the unused
        // MenuBarGeekPanel duplicate row was removed in 1.9.11.
        let sources = try [
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift",
        ].map {
            try r2ProductionSource(at: projectRoot.appendingPathComponent($0))
        }

        // D119 (2026-10-18): the row is iStat's process row, which takes the
        // fallback symbol as `fallbackSymbol:` (was `fallback:`).
        XCTAssertTrue(sources.allSatisfy {
            $0.contains("fallbackSymbol: AppSymbols.Monitor.power")
                && !$0.contains("bolt.app")
        })
        XCTAssertNotNil(NSImage(
            systemSymbolName: AppSymbols.Monitor.power,
            accessibilityDescription: nil
        ))
    }

    func testSecondarySurfaceMatchesReferenceCardGeometry() {
        XCTAssertEqual(GeekPowerLayout.gaugeHeight, 112)
        // D119 (2026-10-18): iStat's battery menu: the 80 pt charge chart
        // (was 79, a 67 pt chart), the 25 pt energy-mode row and a process
        // section of 25 + 17n for up to three apps (was 39, 59 or 79).
        XCTAssertEqual(GeekPowerLayout.historyHeight, 80)
        // D132 (2026-10-19): iStat's battery graph draws its bars from 8 and
        // its rail to 72 (`drawRect:`), so the chart is 80 − 8 − 8; was 66,
        // the bars from 6.
        XCTAssertEqual(GeekPowerLayout.historyChartHeight, 64)
        XCTAssertEqual(GeekPowerLayout.modeHeight, 25)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight, 76)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight(for: 0), 42)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight(for: 1), 42)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight(for: 2), 59)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight(for: 3), 76)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight(for: 5), 76)
        // D119: the battery-electrical and power cards (D57: five power rows
        // on a laptop, three on a desktop) are groups of the sensors page, so
        // the page keeps four sections (was six); the adapter card of a Mac
        // without a battery is a titled group of three rows.
        XCTAssertEqual(GeekPowerLayout.secondaryCardHeights.count, 4)
        XCTAssertEqual(GeekPowerLayout.adapterHeight, GeekSensorReadoutLayout.cardHeight(rowCount: 3))
        // D118 (2026-10-18): iStat's 7 pt card gap (was 6); the level-one
        // battery card is iStat's 40 pt (was 64).
        XCTAssertEqual(MiniWindowStyleTokens.cardSpacing, 7)
        XCTAssertEqual(GeekPowerLayout.secondaryContentHeight, 314)
        XCTAssertEqual(GeekPanelLayout.detailSpacing, MiniWindowStyleTokens.cardSpacing)
        XCTAssertEqual(GeekPanelLayout.overviewPowerCardHeight, 40)
        XCTAssertEqual(GeekPowerLayout.displayedEnergyAppCount, 3)
        // D132 (2026-10-19): the charge chart is iStat's battery menu graph,
        // 69 buckets of 15 minutes; was `detailPreviewDuration`, one hour.
        XCTAssertEqual(GeekPowerLayout.menuGraphDuration, 69 * 900)
        // D119 (2026-10-18): iStat's battery menu is 240 pt wide (was 264).
        XCTAssertEqual(GeekPanelPresentationMetrics.powerDetailWidth, 240)
        XCTAssertEqual(GeekPowerLayout.historyTertiaryOffset, 127)
        // D119: the energy mode follows the chart (was 440 below the
        // electrical and power cards, 211 below the desktop power card).
        XCTAssertEqual(GeekPowerLayout.energyModeTertiaryOffset, 214)
        XCTAssertEqual(
            GeekPowerLayout.energyModeSourceOffset(hasInternalBattery: true),
            214
        )
        XCTAssertEqual(
            GeekPowerLayout.energyModeSourceOffset(hasInternalBattery: false),
            90
        )

        let requiredHeight = GeekPowerLayout.secondaryContentHeight
            + GeekPanelLayout.contentPadding * 2
        XCTAssertEqual(requiredHeight, 330)
        XCTAssertLessThanOrEqual(
            requiredHeight,
            GeekPanelPresentationMetrics.detailSize(for: .power).height
        )
        // D119: the detailed density shows the battery card and the chart.
        XCTAssertEqual(
            GeekPanelPresentationMetrics.detailSize(for: .power, density: .complex).height,
            GeekPanelLayout.contentPadding * 2 + GeekPowerLayout.gaugeHeight
                + GeekPanelLayout.detailSpacing + GeekPowerLayout.historyHeight
        )
    }

    func testBatteryRingStateUsesChargeAndChargingFacts() {
        XCTAssertEqual(
            GeekBatteryRingState.resolve(chargePercent: nil, isCharging: nil),
            .sampling
        )
        XCTAssertEqual(
            GeekBatteryRingState.resolve(chargePercent: 80, isCharging: true),
            .charging
        )
        XCTAssertEqual(
            GeekBatteryRingState.resolve(chargePercent: 80, isCharging: false),
            .notCharging
        )
        XCTAssertEqual(
            GeekBatteryRingState.resolve(chargePercent: 80, isCharging: nil),
            .notCharging
        )
    }

    func testSecondarySurfaceKeepsElectricalDetailsOutOfTheCompactCardStack() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try r2ProductionSource(at: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift"
            ))

        XCTAssertFalse(source.contains("geekPowerElectricalCard"))
        XCTAssertFalse(source.contains("GeekCombinedCard(height: 90)"))
        XCTAssertTrue(source.contains("geekEnergyApps.prefix(GeekPowerLayout.displayedEnergyAppCount)"))
        XCTAssertTrue(source.contains("正在扫描应用…"))
        XCTAssertTrue(source.contains("当前没有显著能耗应用"))
        XCTAssertTrue(source.contains("geekHasEnergyImpactSnapshot"))
        // D119 (2026-10-18): the scanning and empty states are 15 pt rows of
        // the process section (were 19 pt rows).
        XCTAssertFalse(source.contains(".frame(height: 19)"))
        XCTAssertTrue(source.contains("minHeight: GeekIStatSectionGeometry.rowHeight"))
        XCTAssertTrue(source.contains("GeekIStatProcessCard("))
        XCTAssertTrue(source.contains("Text(powerText)"))
        XCTAssertTrue(source.contains("app.currentEvidence.source == .unknown ? \"—\" : app.currentPowerWattsText"))
        XCTAssertTrue(source.contains("app.currentEvidence.detail"))
        let rowRange = try XCTUnwrap(source.range(of: "private struct GeekPowerEnergyAppRow"))
        let energyRow = String(source[rowRange.lowerBound...])
        XCTAssertFalse(energyRow.contains("app.measurementTitle"), "Current watts cannot inherit cumulative evidence")
        XCTAssertTrue(source.contains("statusSymbol: geekBatteryRingSymbol"))
        XCTAssertFalse(source.contains("L10n.text(\"充电中\", \"Charging\")"))
        XCTAssertTrue(source.contains("ProgressView()"))
        XCTAssertFalse(source.contains("Capsule(style: .circular)"))
        XCTAssertFalse(source.contains("GeometryReader"))
        XCTAssertFalse(source.contains("struct GeekPowerBatteryStatusLine: View"))
        XCTAssertFalse(source.contains("typealias GeekPowerBatteryLevelBar"))
        XCTAssertTrue(source.contains("if hasInternalBattery"))
        XCTAssertTrue(source.contains("if hasAvailableEnergyMode"))
        XCTAssertTrue(source.contains("geekEnergyModeGroupCount > 0"))
        XCTAssertTrue(source.contains("geekBatteryPowerMode ?? geekAdapterPowerMode"))

        let gauges = try sourceSegment(
            source,
            from: "private var geekPowerGaugeCard",
            to: "private var geekPowerHistoryCard"
        )
        // D119 (2026-10-18): the memory card's iStat rings, each centered in
        // its half (were 96 pt rings 12 pt apart).
        XCTAssertTrue(gauges.contains("HStack(spacing: 0)"))
        XCTAssertTrue(gauges.contains("size: GeekIStatCardGeometry.memoryRingSize"))
        XCTAssertEqual(GeekIStatCardGeometry.memoryRingSize, 96)
        XCTAssertTrue(gauges.contains("strokeWidth: GeekIStatCardGeometry.memoryRingLineWidth"))
        XCTAssertTrue(gauges.contains("chargePercent: batterySnapshot?.chargePercent"))
        XCTAssertTrue(gauges.contains("healthPercent: geekBatteryHealthPercent"))
        XCTAssertTrue(gauges.contains("statusText: batteryStatusTitle"))
        XCTAssertTrue(gauges.contains("isCharging: batterySnapshot?.isCharging"))
        XCTAssertTrue(gauges.contains("remainingTimeMinutes: batterySnapshot?.remainingTimeMinutes"))
        XCTAssertTrue(gauges.contains("detail: batteryPredictedRuntimeText.map"))
        XCTAssertTrue(gauges.contains("runtimeEstimate: batteryRuntimeEstimate"))

        let history = try sourceSegment(
            source,
            from: "private var geekPowerHistoryCard",
            to: "private var geekPowerModeCard"
        )
        XCTAssertFalse(history.contains("GeekPowerBatteryLevelBar"))
        XCTAssertTrue(history.contains("GeekPowerHistoryChart("))
        XCTAssertTrue(history.contains("metric: .charge"))
        // D132 (2026-10-19): iStat's battery menu graph; was
        // `duration: GeekPowerLayout.detailPreviewDuration` (the last hour).
        XCTAssertTrue(history.contains("duration: GeekPowerLayout.menuGraphDuration"))
        XCTAssertTrue(history.contains("batteryGraph: .menu"))
        XCTAssertTrue(history.contains("points: batteryPowerHistory"))
        XCTAssertTrue(history.contains("chargingTint: panelMetricColors.batteryDraining"))
        XCTAssertTrue(history.contains("sourceOffset: GeekPowerLayout.historyTertiaryOffset"))
        XCTAssertTrue(history.contains("usesCardActiveBorder: true"))
        // D119 (2026-10-18): iStat's 80 pt chart card (was a 67 pt chart).
        // D132: the chart takes the card's width (iStat places its bars from
        // the card's right edge); was the layer inside the 8 pt insets,
        // `.geekIStatLayer(top: GeekIStatSectionGeometry.chargeChartTop, height: GeekPowerLayout.historyChartHeight)`.
        XCTAssertTrue(history.contains(
            ".geekIStatLayer(top: GeekIStatSectionGeometry.chargeChartTop, height: GeekPowerLayout.historyChartHeight,\n"
                + "                                leading: 0, trailing: 0)"
        ))
    }

    func testEnergyCardKeepsCachedRowsAndOnlyUsesScanningForInitialLoad() {
        XCTAssertEqual(
            GeekPowerEnergyCardState.resolve(
                hasCachedSnapshot: false,
                isLoading: true,
                appCount: 0
            ),
            .loading
        )
        XCTAssertEqual(
            GeekPowerEnergyCardState.resolve(
                hasCachedSnapshot: true,
                isLoading: true,
                appCount: 2
            ),
            .apps
        )
        XCTAssertEqual(
            GeekPowerEnergyCardState.resolve(
                hasCachedSnapshot: true,
                isLoading: false,
                appCount: 0
            ),
            .empty
        )
        XCTAssertEqual(
            GeekPowerEnergyCardState.resolve(
                hasCachedSnapshot: false,
                isLoading: false,
                appCount: 0
            ),
            .empty
        )
    }

    func testPowerRangeOnlyFiltersTertiaryHistoryWhilePreviewKeepsTheSharedHourSource() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let panel = try r2ProductionSource(at: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"
            ))
        let hover = try r2ProductionSource(at: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift"
            ))

        let selectedHistory = try sourceSegment(
            panel,
            from: "var powerHistory: [MenuBarPowerHistoryPoint]",
            to: "/// Raw shared battery history"
        )
        let rawHistory = try sourceSegment(
            panel,
            from: "var batteryPowerHistory: [MenuBarPowerHistoryPoint]",
            to: "var healthSummary"
        )

        XCTAssertTrue(selectedHistory.contains("batteryPowerHistory"))
        XCTAssertFalse(selectedHistory.contains("MenuBarHistoryRetention.selected"))
        let kernel = try r2ProductionSource(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerPreparationKernel.swift"))
        // D132 (2026-10-19): iStat's battery graphs select their whole bucket
        // span; the projection keeps `duration` (was
        // `end.addingTimeInterval(-duration)`).
        XCTAssertTrue(kernel.contains("end.addingTimeInterval(-(batteryGraph?.span(for: duration) ?? duration))"))
        XCTAssertTrue(rawHistory.contains("return auxiliaryState.powerHistory"))
        XCTAssertTrue(hover.contains("inlineContentStore.update(hostedDetail, force: true)"))
        XCTAssertFalse(hover.contains("NSPanel("))
        XCTAssertFalse(hover.contains("NSWindow("))
    }

    func testOverviewSeparatesBatteryAndAppPowerCapabilities() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try r2ProductionSource(at: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
            ))
        let summary = try sourceSegment(
            source,
            from: "var geekPowerSummaryCard",
            to: "var geekChartHistory"
        )

        // D118 (2026-10-18): the app-power and adapter cards take the battery
        // card's iStat layout, the power in the title row (were a 35 pt ring,
        // `GeekCombinedRing(` with `size: 35`).
        XCTAssertTrue(summary.contains("GeekModuleHeader(title: L10n.text(\"App 功耗\", \"APP POWER\"))"))
        XCTAssertEqual(
            summary.components(separatedBy: "GeekIStatCard(height: GeekPanelLayout.overviewPowerCardHeight)").count - 1,
            2
        )
        XCTAssertTrue(summary.contains("geekOverviewBatteryStatusText"))
        XCTAssertTrue(summary.contains("geekOverviewPowerSourceAndModeTitle"))
        XCTAssertTrue(summary.contains("geekCurrentPowerMode.map(batteryPowerModeText)"))
        XCTAssertTrue(summary.contains("if hasInternalBattery"))
        XCTAssertTrue(summary.contains("hasConfirmedNoInternalBattery"))
        XCTAssertTrue(summary.contains("geekAppPowerSummaryCard"))
        XCTAssertTrue(summary.contains("snapshot?.currentPowerWattsText"))
        XCTAssertTrue(summary.contains("APP POWER"))
        XCTAssertFalse(summary.contains("GeekBatteryLevelBar"))
        XCTAssertFalse(source.contains("private struct GeekBatteryLevelBar"))

        let batteryCard = try sourceSegment(
            source,
            from: "struct GeekBatteryPresentation: View",
            to: "struct GeekSensorsPresentation: View"
        )
        XCTAssertTrue(batteryCard.contains(
            "height: GeekPanelLayout.overviewPowerCardHeight"
        ))
        XCTAssertTrue(batteryCard.contains("GeometryReader { proxy in"))
        // D118: iStat's 8 pt bar at y 24 (was `.frame(height: 7)`).
        XCTAssertTrue(batteryCard.contains("GeekIStatBar(progress: charge"))
        XCTAssertTrue(batteryCard.contains("height: IStat.batteryBarHeight"))
        XCTAssertEqual(GeekIStatCardGeometry.batteryBarHeight, 8)
        XCTAssertFalse(batteryCard.contains("GeekCombinedRing("))
        XCTAssertFalse(batteryCard.contains("GeekPowerHistoryChart("))

        let overviewModules = try sourceSegment(
            source,
            from: "func geekOverviewModule",
            to: "var geekProcessorCard"
        )
        let powerRoute = try sourceSegment(
            overviewModules,
            from: "case .power:",
            to: "case .memoryBreakdown"
        )
        XCTAssertTrue(powerRoute.contains("GeekOverviewModuleButton(destination: .power"))
        XCTAssertTrue(powerRoute.contains("action: selectGeekSection"))
        XCTAssertFalse(powerRoute.contains("ControlPaletteAnchorButton("))
        let powerDetail = try r2ProductionSource(at: projectRoot.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift"
        ))
        XCTAssertTrue(powerDetail.contains("ControlPaletteHoverAnchor("))
        XCTAssertTrue(powerDetail.contains("kind: .power"))
        XCTAssertTrue(powerDetail.contains("打开电源模式控制"))
        XCTAssertTrue(summary.contains("[batteryPowerSourceTitle, batteryStatusTitle]"))
        XCTAssertFalse(powerRoute.contains("Image(systemName: AppSymbols.Panel.attachedDetail)"))
        XCTAssertFalse(powerRoute.contains("selectGeekHardwareDetail(.power)"))
        XCTAssertTrue(source.contains("case .power:\n                return showsOverviewPowerModule"))
        XCTAssertTrue(source.contains("return hasInternalBattery"))
    }

    func testBatterylessOverviewRemovesExactlyThePowerCardFootprint() {
        let fullSize = GeekPanelLayout.overviewSize(showsPowerModule: true)
        let batterylessSize = GeekPanelLayout.overviewSize(showsPowerModule: false)

        XCTAssertEqual(fullSize.width, MiniWindowStyleTokens.overviewSize.width)
        // CPU's reference-calibrated card is 12 pt taller; the hardware-
        // absence contract below must still remove exactly one card and gap.
        // D118 (2026-10-18): iStat's combined menu, 8 + 120 + 112 + 42 + 100
        // + 88 + 40 + 5 × 7 + 8 (was 605, fix1 B1). The fan entry still sits
        // inside the sensor card's footprint.
        XCTAssertEqual(fullSize.height, 553)
        XCTAssertEqual(batterylessSize.width, fullSize.width)
        XCTAssertEqual(
            batterylessSize.height,
            fullSize.height
                - GeekPanelLayout.overviewPowerCardHeight
                - GeekPanelLayout.sectionSpacing
        )
    }

    func testOverviewTracksVisibleCardsWithoutReservingHiddenModuleSpace() {
        let modules: [GeekDashboardModule] = [.processorGraphics, .coreMetrics, .disk, .network, .sensors, .power]
        let full = GeekPanelLayout.overviewSize(modules: modules)
        let withoutMemory = GeekPanelLayout.overviewSize(modules: modules.filter { $0 != .coreMetrics })
        XCTAssertEqual(full.height - withoutMemory.height, GeekPanelLayout.overviewMemoryCardHeight + GeekPanelLayout.sectionSpacing)
        XCTAssertEqual(GeekPanelLayout.overviewSize(modules: [.power]).height,
                       GeekPanelLayout.overviewPowerCardHeight + GeekPanelLayout.contentPadding * 2)
        XCTAssertEqual(GeekPanelLayout.overviewSize(modules: []).height, GeekPanelLayout.contentPadding * 2)
    }

    func testInternalBatteryPresenceAcceptsIndependentDeviceEvidence() {
        XCTAssertFalse(InternalBatteryPresence.resolve(
            hasPowerSnapshot: false,
            hasElectricalBatteryData: false,
            hasHealthSnapshot: false
        ))
        XCTAssertTrue(InternalBatteryPresence.resolve(
            hasPowerSnapshot: true,
            hasElectricalBatteryData: false,
            hasHealthSnapshot: false
        ))
        XCTAssertTrue(InternalBatteryPresence.resolve(
            hasPowerSnapshot: false,
            hasElectricalBatteryData: true,
            hasHealthSnapshot: false
        ))
        XCTAssertTrue(InternalBatteryPresence.resolve(
            hasPowerSnapshot: false,
            hasElectricalBatteryData: false,
            hasHealthSnapshot: true
        ))
        XCTAssertFalse(InternalBatteryPresence.resolve(
            hasExplicitNoBatteryEvidence: true,
            hasPowerSnapshot: true,
            hasElectricalBatteryData: true,
            hasHealthSnapshot: true
        ))
    }

    func testInternalBatteryViewCapabilityUsesPowerElectricalAndHealthEvidence() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try r2ProductionSource(at: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
            ))

        XCTAssertTrue(source.contains("hasPowerSnapshot: batterySnapshot != nil"))
        XCTAssertTrue(source.contains("hasElectricalBatteryData: batteryElectricalSnapshot?.hasBatteryData == true"))
        XCTAssertTrue(source.contains("hasHealthSnapshot: computerHealthStore.snapshot?.battery != nil"))
        XCTAssertTrue(source.contains("if case .notPresent? = computerHealthStore.snapshot?.batteryEvidence"))
    }

    func testPowerSurfacesShowAdapterReadingsWithoutInventingBatteryData() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try r2ProductionSource(at: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift"
            ))
        let detail = try sourceSegment(
            source,
            from: "private var tertiaryPowerDetail",
            to: "private struct TertiaryMultilineValueRow"
        )
        let powerPage = try r2ProductionSource(at: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift"
            ))

        XCTAssertTrue(detail.contains("if hasInternalBattery"))
        XCTAssertTrue(detail.contains("Current Electrical Readings"))
        XCTAssertTrue(detail.contains("Input Power"))
        XCTAssertTrue(detail.contains("Input Voltage"))
        XCTAssertTrue(detail.contains("Input Current"))
        XCTAssertTrue(detail.contains("Battery Power · Last \\(geekChartRangeTitle)"))
        XCTAssertFalse(detail.contains("Latest On-Demand Energy Measurement"))
        let page = try sourceSegment(powerPage, from: "var geekPowerPage: some View", to: "var batteryRuntimeEstimate")
        XCTAssertTrue(page.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .contains("} else { geekPowerAdapterCard }"))
        XCTAssertTrue(powerPage.contains("Negotiated Power"))
        XCTAssertTrue(powerPage.contains("Negotiated Voltage"))
        XCTAssertTrue(powerPage.contains("Negotiated Current"))
        XCTAssertTrue(powerPage.contains("this is the negotiated input specification, not a wall-meter reading"))
        XCTAssertTrue(powerPage.contains("batteryElectricalSnapshot?.adapterVoltageVolts"))
        XCTAssertTrue(powerPage.contains("batteryElectricalSnapshot?.adapterAmperageAmps"))
    }

    private func sourceSegment(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
            throw NSError(domain: "GeekPowerViewTests", code: 1)
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
