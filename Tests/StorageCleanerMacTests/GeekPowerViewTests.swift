import AppKit
import XCTest
@testable import StorageCleanerMac

final class GeekPowerViewTests: XCTestCase {
    func testEnergyModeCardUsesHoverAttachedControlPalette() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift"
            ),
            encoding: .utf8
        )
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
            try String(
                contentsOf: projectRoot.appendingPathComponent($0),
                encoding: .utf8
            )
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
        XCTAssertEqual(GeekPowerLayout.secondaryCardHeights.count, 4)
        XCTAssertEqual(GeekPowerLayout.secondaryContentHeight, 310)
        XCTAssertEqual(GeekPanelLayout.detailSpacing, MiniWindowStyleTokens.cardSpacing)
        XCTAssertEqual(GeekPanelLayout.overviewPowerCardHeight, 60)
        XCTAssertEqual(GeekPowerLayout.displayedEnergyAppCount, 3)
        XCTAssertEqual(GeekPowerLayout.detailPreviewDuration, GeekChartRange.oneHour.duration)
        XCTAssertEqual(GeekPanelPresentationMetrics.powerDetailWidth, 264)
        XCTAssertEqual(GeekPowerLayout.historyTertiaryOffset, 125)
        XCTAssertEqual(GeekPowerLayout.energyModeTertiaryOffset, 209)
        XCTAssertEqual(
            GeekPowerLayout.energyModeSourceOffset(hasInternalBattery: true),
            209
        )
        XCTAssertEqual(
            GeekPowerLayout.energyModeSourceOffset(hasInternalBattery: false),
            GeekPanelLayout.contentPadding
        )

        let requiredHeight = GeekPowerLayout.secondaryContentHeight
            + GeekPanelLayout.detailSpacing
            + 33
            + GeekPanelLayout.contentPadding * 2
        XCTAssertEqual(requiredHeight, 364)
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
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("geekPowerElectricalCard"))
        XCTAssertFalse(source.contains("GeekCombinedCard(height: 90)"))
        XCTAssertTrue(source.contains("geekEnergyApps.prefix(GeekPowerLayout.displayedEnergyAppCount)"))
        XCTAssertTrue(source.contains("正在扫描应用…"))
        XCTAssertTrue(source.contains("当前没有显著能耗应用"))
        XCTAssertTrue(source.contains("geekHasEnergyImpactSnapshot"))
        XCTAssertTrue(source.contains(".frame(height: 19)"))
        XCTAssertTrue(source.contains("Text(app.currentPowerWattsText)"))
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
        XCTAssertTrue(history.contains("chargingTint: GeekBatteryChartPalette.battery"))
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
        let panel = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"
            ),
            encoding: .utf8
        )
        let hover = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift"
            ),
            encoding: .utf8
        )

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
        XCTAssertTrue(selectedHistory.contains("duration: selectedChartRange.duration"))
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
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
            ),
            encoding: .utf8
        )
        let summary = try sourceSegment(
            source,
            from: "var geekPowerSummaryCard",
            to: "var geekSystemLoadCard"
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
            summary,
            from: "private var geekBatterySummaryCard",
            to: "private var geekAppPowerSummaryCard"
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
        let powerDetail = try String(contentsOf: projectRoot.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift"
        ), encoding: .utf8)
        XCTAssertTrue(powerDetail.contains("ControlPaletteHoverAnchor("))
        XCTAssertTrue(powerDetail.contains("kind: .power"))
        XCTAssertTrue(powerDetail.contains("打开电源模式控制"))
        XCTAssertTrue(summary.contains("[batteryPowerSourceTitle, batteryStatusTitle]"))
        XCTAssertFalse(powerRoute.contains("Image(systemName: AppSymbols.Panel.attachedDetail)"))
        XCTAssertFalse(powerRoute.contains("selectGeekHardwareDetail(.power)"))
        XCTAssertTrue(source.contains("case .power:\n                return showsOverviewPowerModule"))
        XCTAssertTrue(source.contains("return !hasConfirmedNoInternalBattery"))
    }

    func testBatterylessOverviewRemovesExactlyThePowerCardFootprint() {
        let fullSize = GeekPanelLayout.overviewSize(showsPowerModule: true)
        let batterylessSize = GeekPanelLayout.overviewSize(showsPowerModule: false)

        XCTAssertEqual(fullSize.width, MiniWindowStyleTokens.overviewSize.width)
        XCTAssertEqual(fullSize.height, 564)
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
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
            ),
            encoding: .utf8
        )

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
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift"
            ),
            encoding: .utf8
        )
        let detail = try sourceSegment(
            source,
            from: "private var tertiaryPowerDetail",
            to: "private struct TertiaryMultilineValueRow"
        )
        let powerPage = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(detail.contains("if hasInternalBattery"))
        XCTAssertTrue(detail.contains("Current Electrical Readings"))
        XCTAssertTrue(detail.contains("Input Power"))
        XCTAssertTrue(detail.contains("Input Voltage"))
        XCTAssertTrue(detail.contains("Input Current"))
        XCTAssertTrue(detail.contains("Battery Power · Last \\(geekChartRangeTitle)"))
        XCTAssertTrue(detail.contains("Latest On-Demand Energy Measurement"))
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
