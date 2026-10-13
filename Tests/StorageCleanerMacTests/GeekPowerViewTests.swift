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

        XCTAssertTrue(sources.allSatisfy {
            $0.contains("fallback: AppSymbols.Monitor.power")
                && !$0.contains("bolt.app")
        })
        XCTAssertNotNil(NSImage(
            systemSymbolName: AppSymbols.Monitor.power,
            accessibilityDescription: nil
        ))
    }

    func testSecondarySurfaceMatchesReferenceCardGeometry() {
        XCTAssertEqual(GeekPowerLayout.gaugeHeight, 112)
        XCTAssertEqual(GeekPowerLayout.historyHeight, 79)
        XCTAssertEqual(GeekPowerLayout.modeHeight, 25)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight, 79)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight(for: 0), 39)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight(for: 1), 39)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight(for: 2), 59)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight(for: 3), 79)
        XCTAssertEqual(GeekPowerLayout.significantEnergyHeight(for: 5), 79)
        XCTAssertEqual(GeekPowerLayout.secondaryCardHeights.count, 6)
        // D57: the power card lists five rows (computer, power input,
        // battery, display backlight, chip total), 46 pt more than three.
        XCTAssertEqual(GeekPowerLayout.powerHeight, GeekSensorReadoutLayout.cardHeight(rowCount: 5))
        XCTAssertEqual(GeekPowerLayout.desktopPowerHeight, GeekSensorReadoutLayout.cardHeight(rowCount: 3))
        XCTAssertEqual(GeekPowerLayout.secondaryContentHeight, 538)
        XCTAssertEqual(GeekPanelLayout.detailSpacing, MiniWindowStyleTokens.cardSpacing)
        XCTAssertEqual(GeekPanelLayout.overviewPowerCardHeight, 64)
        XCTAssertEqual(GeekPowerLayout.displayedEnergyAppCount, 3)
        XCTAssertEqual(GeekPowerLayout.detailPreviewDuration, GeekChartRange.oneHour.duration)
        XCTAssertEqual(GeekPanelPresentationMetrics.powerDetailWidth, 264)
        XCTAssertEqual(GeekPowerLayout.historyTertiaryOffset, 126)
        XCTAssertEqual(GeekPowerLayout.energyModeTertiaryOffset, 436)
        XCTAssertEqual(
            GeekPowerLayout.energyModeSourceOffset(hasInternalBattery: true),
            436
        )
        XCTAssertEqual(
            GeekPowerLayout.energyModeSourceOffset(hasInternalBattery: false),
            209
        )

        let requiredHeight = GeekPowerLayout.secondaryContentHeight
            + GeekPanelLayout.detailSpacing
            + 33
            + GeekPanelLayout.contentPadding * 2
        XCTAssertEqual(requiredHeight, 593)
        XCTAssertLessThanOrEqual(
            requiredHeight,
            GeekPanelPresentationMetrics.detailSize(for: .power).height
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
        XCTAssertTrue(source.contains(".frame(height: 19)"))
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
        XCTAssertTrue(gauges.contains("HStack(spacing: 12)"))
        XCTAssertTrue(gauges.contains("size: 96"))
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
        XCTAssertTrue(history.contains("duration: GeekPowerLayout.detailPreviewDuration"))
        XCTAssertTrue(history.contains("points: batteryPowerHistory"))
        XCTAssertTrue(history.contains("chargingTint: panelMetricColors.batteryDraining"))
        XCTAssertTrue(history.contains("sourceOffset: GeekPowerLayout.historyTertiaryOffset"))
        XCTAssertTrue(history.contains("usesCardActiveBorder: true"))
        XCTAssertTrue(history.contains(".frame(height: 67)"))
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
        XCTAssertTrue(kernel.contains("end.addingTimeInterval(-duration)"))
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

        XCTAssertTrue(summary.contains("GeekCombinedRing("))
        XCTAssertTrue(summary.contains("size: 35"))
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
        XCTAssertTrue(batteryCard.contains(".frame(height: 7)"))
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
        XCTAssertEqual(fullSize.height, 605) // fix1 B1: the entry belongs inside the unchanged sensor-card footprint.
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
        XCTAssertTrue(powerPage.contains("else {\n                geekPowerAdapterCard"))
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
