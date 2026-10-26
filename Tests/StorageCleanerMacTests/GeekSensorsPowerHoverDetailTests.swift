import CoreGraphics
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class GeekSensorsPowerHoverDetailTests: XCTestCase {
    func testCapturedReferencePopoverSizesRemainExplicit() throws {
        // D121 (2026-10-18): the graph card alone; rows below it add to the
        // page (`GeekSensorMetricHoverDetail.popoverSize`). Was 250 for the
        // stacked range row and a second reading.
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.sensorHistorySize,
            CGSize(width: MiniWindowStyleTokens.historyWidth, height: 216)
        )
        // D122 (2026-10-18): one titled iStat card per section, sized by its
        // rows: power and charging 2, battery 4, health 3, cells 3, one
        // USB-C port (was the compact two-column grid's fixed 220 × 196).
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.batterySize(sectionRowCounts: [2, 4, 3, 3, 1]),
            CGSize(width: 220, height: 385)
        )
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.batterySize(sectionRowCounts: [3]),
            CGSize(width: 220, height: 91)
        )
        // D132 (2026-10-19): iStat's battery history submenu, 319 × (180 +
        // 2 × 8); was `GeekHoverDetailMetrics.compactHistorySize` (391 × 216).
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.batteryHistorySize,
            CGSize(width: 319, height: 196)
        )
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.energyModeSize,
            CGSize(width: 170, height: 167)
        )
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.energyModeSize(groupCount: 1),
            CGSize(width: 170, height: 88)
        )
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.energyModeSize(groupCount: 2),
            CGSize(width: 170, height: 167)
        )
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.energyModeSize(rowCounts: [2]),
            CGSize(width: 170, height: 70)
        )
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.energyModeSize(rowCounts: [2, 2]),
            CGSize(width: 170, height: 132)
        )
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.compactSamplingSize,
            CGSize(width: 220, height: 148)
        )
        let hardware = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHardwareControlView.swift")
        XCTAssertFalse(hardware.contains("authorizationHeight"))
        let palette = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift")
        XCTAssertTrue(palette.contains("ControlPaletteHelperStatusView("))
        // D73 deletes the dead card implementation; lock the live entry's geometry instead.
        // D119 (2026-10-18): the entry is a 15 pt row of iStat's fan group,
        // its hit area the 17 pt pitch (was a 24 pt row).
        XCTAssertEqual(FanControlEntryRow.height, 15)
        XCTAssertEqual(FanControlEntryRow.height, GeekIStatSectionGeometry.rowHeight)
        XCTAssertTrue(hardware.contains(".contentShape(Rectangle().inset(by: -GeekIStatSectionGeometry.rowGap / 2))"))
        XCTAssertFalse(hardware.contains("struct GeekFanControlCard"))
        XCTAssertFalse(hardware.contains("struct GeekPowerModeControlCard"))
    }

    func testHistoryPopoverStaysCompactUntilTwoValidSamplesExist() {
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.popoverSize(
                sampleCount: 0,
                expandedSize: GeekSensorPowerHoverDetailMetrics.sensorHistorySize
            ),
            GeekSensorPowerHoverDetailMetrics.compactSamplingSize
        )
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.popoverSize(
                sampleCount: 1,
                expandedSize: GeekSensorPowerHoverDetailMetrics.sensorHistorySize
            ),
            GeekSensorPowerHoverDetailMetrics.compactSamplingSize
        )
        XCTAssertEqual(
            GeekSensorPowerHoverDetailMetrics.popoverSize(
                sampleCount: 2,
                expandedSize: GeekSensorPowerHoverDetailMetrics.sensorHistorySize
            ),
            GeekSensorPowerHoverDetailMetrics.sensorHistorySize
        )
    }

    func testBatteryDetailsMatchTheCompactReferenceHierarchy() throws {
        let source = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift"
        )
        let electrical = try XCTUnwrap(
            source.components(separatedBy: "struct GeekBatteryElectricalHoverDetail").last?
                .components(separatedBy: "struct GeekBatteryHistoryHoverDetail").first
        )
        for title in ["Charge", "Health", "Status", "Power-based Runtime", "Adapter Power", "Effective Charge Limit", "Cycles", "Condition", "Battery Temperature"] {
            XCTAssertTrue(electrical.contains("\"\(title)\""), title)
        }
        for removedTitle in ["Power Source", "Design Capacity", "Current Capacity", "Recent Draw", "Adapter", "Charging Power", "Negotiated", "Not Charging"] {
            XCTAssertFalse(electrical.contains("\"\(removedTitle)\""), removedTitle)
        }
        XCTAssertTrue(electrical.contains("chargePercent: Int?"))
        XCTAssertTrue(electrical.contains("healthPercent: Int?"))
        XCTAssertTrue(electrical.contains("isCharging: Bool?"))
        XCTAssertTrue(electrical.contains("chargeTargetPercent: Int?"))
        XCTAssertFalse(electrical.contains("powerSource: BatteryPowerSource?"))
        XCTAssertTrue(electrical.contains("remainingTimeMinutes: Int?"))
        XCTAssertTrue(electrical.contains("runtimeEstimate: GeekBatteryRemainingTime.Estimate?"))
        let body = try XCTUnwrap(
            electrical.components(separatedBy: "private var batteryRows").first?
                .components(separatedBy: "var body: some View").last
        )
        XCTAssertTrue(body.contains(".padding(pageProvidesInset ? 0 : GeekPanelLayout.contentPadding)"))
        XCTAssertFalse(body.contains(".padding(7)"))
        XCTAssertFalse(body.contains("maxHeight: .infinity"))
        XCTAssertFalse(body.contains("L10n.text(\"不可用\", \"Unavailable\")"))
        XCTAssertTrue(electrical.contains("electrical?.adapterPowerWatts"))
        XCTAssertFalse(electrical.contains("electrical?.powerWatts"))
        XCTAssertTrue(electrical.contains("if !chargingRows.isEmpty"))
        XCTAssertTrue(electrical.contains("if !healthRows.isEmpty"))

        let history = try XCTUnwrap(
            source.components(separatedBy: "struct GeekBatteryHistoryHoverDetail").last?
                .components(separatedBy: "struct GeekEnergyModeHoverDetail").first
        )
        XCTAssertTrue(history.contains("L10n.text(\"电池\", \"Battery\").uppercased()"))
        XCTAssertTrue(history.contains("chargingTint: chargingTint"))
        // Batch 2b review: the chart sits in the shared history plot block.
        // D132 (2026-10-19): iStat's battery history has no axis row, its
        // card is 180 tall with the plot block from 30; was framed above
        // `.geekHistoryAxis(GeekHistoryAxisFooter(duration: chartRangeSelection.range.duration`.
        XCTAssertFalse(history.contains(".geekHistoryAxis("))
        XCTAssertTrue(history.contains("cardHeight: GeekIStatHistoryGeometry.batteryCardHeight"))
        XCTAssertTrue(history.contains("plotTop: GeekIStatHistoryGeometry.batteryPlotTop"))
        XCTAssertTrue(history.contains("availableRanges: GeekIStatBatteryGraph.historyRanges"))
        XCTAssertTrue(history.contains("batteryGraph: .history"))
        XCTAssertFalse(history.contains("GeekPowerBatteryLevelBar"))

        let energyMode = try XCTUnwrap(
            source.components(separatedBy: "struct GeekEnergyModeHoverDetail").last?
                .components(separatedBy: "enum GeekEnergyModePowerTitle").first
        )
        XCTAssertTrue(energyMode.contains(".frame(maxWidth: .infinity, alignment: .topLeading)"))
        XCTAssertFalse(energyMode.contains("maxHeight: .infinity"))
    }

    func testDedicatedPowerHistoryMetricReadsOnlyItsRealField() {
        let point = MenuBarPowerHistoryPoint(
            date: Date(timeIntervalSince1970: 100),
            chargePercent: 73,
            batteryPowerWatts: -4.25
        )

        XCTAssertEqual(GeekPowerHistoryMetric.charge.value(in: point), 73)
        XCTAssertEqual(GeekPowerHistoryMetric.batteryPower.value(in: point), -4.25)
        XCTAssertEqual(GeekPowerHistoryMetric.charge.formatted(73), "73%")
        XCTAssertEqual(GeekPowerHistoryMetric.batteryPower.formatted(-4.25), "-4.25 W")
        XCTAssertEqual(
            GeekPowerHistoryMetric.charge.title,
            L10n.text("电量", "Charge")
        )
        XCTAssertEqual(
            GeekPowerHistoryMetric.batteryPower.currentText(8),
            L10n.text("当前 +8.00 W · 充电", "Current +8.00 W · Charging")
        )
        XCTAssertEqual(
            GeekPowerHistoryMetric.batteryPower.currentText(-4.25),
            L10n.text("当前 -4.25 W · 放电", "Current -4.25 W · Discharging")
        )
        // r2-mini-sensors review item 7: a zero has no sign (was "+0.00 W").
        XCTAssertEqual(
            GeekPowerHistoryMetric.batteryPower.currentText(0),
            L10n.text("当前 0.00 W · 空闲", "Current 0.00 W · Idle")
        )
    }

    func testPowerTertiaryKeepsRuntimeSourcesExplicitOnBattery() throws {
        let source = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift"
        )
        let powerDetail = try XCTUnwrap(
            source.components(separatedBy: "private var tertiaryPowerDetail").last?
                .components(separatedBy: "private var tertiaryCleanupDetail").first
        )

        XCTAssertTrue(powerDetail.contains("batterySnapshot?.powerSource != .batteryPower"))
        for title in ["Power-based Runtime", "Recent Draw", "macOS Runtime", "Full Charge In"] {
            XCTAssertTrue(powerDetail.contains("\"\(title)\""), title)
        }
    }

    func testEnergyModeTitlesExposeOnlyValidatedNativeWattage() {
        XCTAssertEqual(
            GeekEnergyModePowerTitle.overviewACSummary(
                powerSource: .acPower,
                adapterWatts: 65,
                targetPercent: 80
            ),
            L10n.text("适配器 65 W · 目标 80%", "Adapter 65 W · Target 80%")
        )
        XCTAssertEqual(
            GeekEnergyModePowerTitle.overviewACSummary(
                powerSource: .acPower,
                adapterWatts: nil,
                targetPercent: 80
            ),
            L10n.text("目标 80%", "Target 80%")
        )
        XCTAssertNil(
            GeekEnergyModePowerTitle.overviewACSummary(
                powerSource: .acPower,
                adapterWatts: nil,
                targetPercent: nil
            )
        )
        XCTAssertNil(
            GeekEnergyModePowerTitle.overviewACSummary(
                powerSource: .batteryPower,
                adapterWatts: 65,
                targetPercent: 80
            )
        )
        // D128 (2026-10-19): iStat's power format, at most one decimal (was "28 W").
        XCTAssertEqual(
            GeekEnergyModePowerTitle.battery(isCharging: true, watts: 28.4),
            L10n.text("电池 · 充电 28.4 W", "Battery · Charging 28.4 W")
        )
        XCTAssertEqual(
            GeekEnergyModePowerTitle.adapter(watts: 65),
            "\(L10n.text("电源适配器", "Power Adapter")) · 65 W"
        )
        XCTAssertEqual(
            GeekEnergyModePowerTitle.battery(isCharging: false, watts: 28.4),
            L10n.text("电池", "Battery")
        )
        XCTAssertEqual(
            GeekEnergyModePowerTitle.adapter(watts: .nan),
            L10n.text("电源适配器", "Power Adapter")
        )
    }

    func testRemainingTimeTreatsZeroAndNegativeEstimatesAsUnavailable() {
        XCTAssertNil(GeekBatteryRemainingTime.text(for: nil))
        XCTAssertNil(GeekBatteryRemainingTime.text(for: 0))
        XCTAssertNil(GeekBatteryRemainingTime.text(for: -1))
        XCTAssertEqual(
            GeekBatteryRemainingTime.text(for: 30),
            L10n.text("30 分钟", "30m")
        )
    }

    func testPowerBasedRuntimeUsesRecentMedianDrawAndRemainingCapacity() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = BatteryPowerSnapshot(
            chargePercent: 72,
            isCharging: false,
            powerSource: .batteryPower,
            timeToEmptyMinutes: 266,
            timeToFullChargeMinutes: nil
        )
        let electrical = NativeBatteryElectricalSnapshot(
            generatedAt: now,
            voltageVolts: 12.1,
            amperageAmps: -7 / 12.1,
            powerWatts: -7,
            temperatureCelsius: 32,
            adapterPowerWatts: nil,
            adapterVoltageVolts: nil,
            adapterAmperageAmps: nil,
            adapterName: nil,
            designCapacityMAh: 5_100,
            currentCapacityMAh: 3_876,
            maximumCapacityMAh: 4_760,
            cycleCount: 108,
            condition: .normal
        )
        let history = [6.0, 30.0, 7.0, 8.0, 7.0].enumerated().map { index, watts in
            MenuBarPowerHistoryPoint(
                date: now.addingTimeInterval(Double(index - 4) * 30),
                chargePercent: 72,
                batteryPowerWatts: -watts,
                isCharging: false,
                powerSource: .batteryPower
            )
        }

        let estimate = try XCTUnwrap(GeekBatteryRemainingTime.estimate(
            snapshot: snapshot,
            electrical: electrical,
            history: history,
            referenceDate: now
        ))

        XCTAssertEqual(estimate.minutes, 355)
        XCTAssertEqual(estimate.powerWatts, 7, accuracy: 0.001)
        XCTAssertEqual(estimate.sampleCount, 5)
    }

    func testPowerBasedRuntimeRequiresAStableRecentBatteryWindow() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let battery = BatteryPowerSnapshot(
            chargePercent: 70,
            isCharging: false,
            powerSource: .batteryPower,
            timeToEmptyMinutes: nil,
            timeToFullChargeMinutes: nil
        )
        let electrical = NativeBatteryElectricalSnapshot(
            generatedAt: now,
            voltageVolts: 12,
            amperageAmps: -0.5,
            powerWatts: -6,
            temperatureCelsius: nil,
            adapterPowerWatts: nil,
            adapterVoltageVolts: nil,
            adapterAmperageAmps: nil,
            adapterName: nil,
            designCapacityMAh: 5_000,
            currentCapacityMAh: 3_500,
            maximumCapacityMAh: 5_000,
            cycleCount: nil,
            condition: nil
        )
        let oneSample = [MenuBarPowerHistoryPoint(
            date: now,
            chargePercent: 70,
            batteryPowerWatts: -6,
            isCharging: false,
            powerSource: .batteryPower
        )]

        XCTAssertNil(GeekBatteryRemainingTime.estimate(
            snapshot: battery,
            electrical: electrical,
            history: oneSample,
            referenceDate: now
        ))
        XCTAssertNil(GeekBatteryRemainingTime.estimate(
            snapshot: BatteryPowerSnapshot(
                chargePercent: 70,
                isCharging: true,
                powerSource: .acPower,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: 40
            ),
            electrical: electrical,
            history: oneSample + oneSample,
            referenceDate: now
        ))
    }

    func testTemperatureLayoutShowsOnlyAvailableRegionalSensors() {
        let zones = GeekTemperatureZoneLayout.displayZones(available: [.chip, .battery, .storage])

        XCTAssertEqual(zones, [.chip, .storage, .battery])
        XCTAssertFalse(zones.contains(.ambient))
        XCTAssertFalse(zones.contains(.gpu))
    }

    func testTemperatureLayoutDoesNotSynthesizeMissingCPUClusterRows() {
        let zones = GeekTemperatureZoneLayout.displayZones(available: [.performanceCores])

        XCTAssertEqual(zones, [.performanceCores])
        XCTAssertFalse(zones.contains(.chip))
        XCTAssertFalse(zones.contains(.soc))
        XCTAssertFalse(zones.contains(.efficiencyCores))
    }

    func testTemperatureLayoutKeepsARealSoCReadingWithoutAddingCPUPlaceholder() {
        let zones = GeekTemperatureZoneLayout.displayZones(available: [.soc])

        XCTAssertEqual(zones, [.soc])
        XCTAssertFalse(zones.contains(.chip))
    }

    func testTemperatureLayoutKeepsEveryAvailableZoneInStableOrder() {
        let zones = GeekTemperatureZoneLayout.displayZones(available: [
            .wifi,
            .efficiencyCores,
            .superCores,
            .performanceCores,
            .soc,
            .chip,
            .gpu,
            .ambient,
        ])

        XCTAssertEqual(zones, [
            .chip,
            .soc,
            .performanceCores,
            .efficiencyCores,
            .superCores,
            .gpu,
            .ambient,
            .wifi,
        ])
    }

    func testEveryTemperatureZoneHasADedicatedHistoryChannel() {
        let readings = SystemTemperatureZone.allCases.enumerated().map { index, zone in
            SystemTemperatureReading(zone: zone, celsius: 40 + Double(index))
        }
        let point = MenuBarTelemetryPoint(
            snapshot: SystemMonitorSnapshot(
                generatedAt: Date(timeIntervalSince1970: 200),
                metrics: [],
                networkThroughput: nil,
                temperatureReadings: readings
            )
        )

        for reading in readings {
            XCTAssertEqual(
                MenuBarTelemetryChannel.temperature(reading.zone).value(in: point),
                reading.celsius
            )
        }
    }

    func testSensorPageDistinguishesSamplingFromConfirmedUnavailableHardware() {
        XCTAssertEqual(
            GeekSensorPageAvailability.resolve(
                reportedAvailability: .sampling,
                hasSensorData: false
            ),
            .sampling
        )
        XCTAssertEqual(
            GeekSensorPageAvailability.resolve(
                reportedAvailability: .unavailable,
                hasSensorData: false
            ),
            .unavailable
        )
        XCTAssertEqual(
            GeekSensorPageAvailability.resolve(
                reportedAvailability: .unavailable,
                hasSensorData: true
            ),
            .available
        )
    }

    /// D119: the temperature group is iStat's single column of 15 pt rows on
    /// the 17 pt pitch under a title, 24 + 17n (was a two-column grid of 18 pt
    /// rows under 26 pt of chrome). The level-three probe list keeps its
    /// two-column grid.
    func testTemperatureGroupUsesIStatRowsAndProbeListKeepsTwoColumns() throws {
        XCTAssertEqual(GeekIStatSectionGeometry.rowHeight, 15)
        XCTAssertEqual(GeekIStatSectionGeometry.rowPitch, 17)
        XCTAssertEqual(GeekSensorReadoutLayout.cardHeight(rowCount: 0), 41, "an empty group keeps one row")
        XCTAssertEqual(GeekSensorReadoutLayout.cardHeight(rowCount: 1), 41)
        XCTAssertEqual(GeekSensorReadoutLayout.cardHeight(rowCount: 3), 75)
        XCTAssertEqual(GeekSensorReadoutLayout.cardHeight(rowCount: 4), 92)
        XCTAssertEqual(GeekSensorReadoutLayout.cardHeight(rowCount: 10), 194)
        XCTAssertEqual(GeekSensorTemperatureLayout.gridColumnSpacing, 10)
        XCTAssertEqual(
            GeekSensorTemperatureLayout.temperatureGridRowCount(itemCount: 13),
            7
        )

        let source = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift")
        let card = try XCTUnwrap(
            source.components(separatedBy: "private var geekTemperatureCard: some View {").last?
                .components(separatedBy: "private var geekDetailedTemperatures:").first
        )
        XCTAssertTrue(card.contains("GeekIStatRowsCard("))
        XCTAssertTrue(card.contains("rowCount: geekDisplayedTemperatures.count + (showsProbes ? 1 : 0)"))
        XCTAssertFalse(card.contains("LazyVGrid"), "the zones are one column now")
    }

    func testPowerHistoryUsesSharedTimestampAwareBarLayout() throws {
        let source = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift"
        )
        let chart = try XCTUnwrap(
            source.components(separatedBy: "struct GeekPowerHistoryChart").last?
                .components(separatedBy: "struct GeekFanHoverDetail").first
        )

        let kernel = try self.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerPreparationKernel.swift")
        XCTAssertTrue(kernel.contains("GeekChartWindow.barRange("))
        XCTAssertTrue(chart.contains("GeekChartWindow.barMarkWidth"))
        XCTAssertTrue(chart.contains("GeekPowerHistoryScale.chargeBarWidth"))
        XCTAssertTrue(kernel.contains("GeekChartWindow.displayBuckets("))
        XCTAssertTrue(chart.contains("private func preparedBatteryBuckets("))
        XCTAssertTrue(kernel.contains("TimeBucketAggregator.nearestFilled("))
        XCTAssertTrue(kernel.contains("TimeBucketAggregator.forwardFilled("))
        XCTAssertTrue(chart.contains("GeekLiveChartTimeline(duration: duration)"))
        XCTAssertTrue(chart.contains("chartContent(referenceDate: referenceDate)"))
        XCTAssertFalse(chart.contains("chargeReferenceDate"))
        XCTAssertTrue(chart.contains("PowerConnectionTimeline.segment("))
        XCTAssertTrue(chart.contains("usablePoints(endingAt: referenceDate)"))
        XCTAssertGreaterThanOrEqual(
            chart.components(separatedBy: "referenceDate: referenceDate").count - 1,
            8
        )
        XCTAssertTrue(chart.contains("GeekHoverTooltip("))
        XCTAssertTrue(chart.contains("metric.currentText(statistics.current)"))
        XCTAssertTrue(chart.contains("guard case .batteryPower = metric else { return }"))
        XCTAssertTrue(chart.contains("drawPowerConnectionTimeline("))
        XCTAssertTrue(chart.contains("PowerConnectionTimeline.connectedRuns"))
        XCTAssertTrue(chart.contains("drawLightningBolt("))
        XCTAssertTrue(chart.contains("barColor(for: point)"))
        XCTAssertTrue(source.contains("static let health = MiniWindowColorPalette.pink"))
        XCTAssertTrue(chart.contains("GeekChartDrawing.bar("))
        XCTAssertFalse(chart.contains("GeekPowerHistoryBarLayout"))
    }

    func testPowerHistoryPreviewLeavesHoverTrackingToItsContainingDetailTarget() throws {
        let power = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift")
        let details = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift"
        )
        let historyCard = try XCTUnwrap(
            power.components(separatedBy: "private var geekPowerHistoryCard").last?
                .components(separatedBy: "private var geekPowerModeCard").first
        )
        let tracking = try XCTUnwrap(
            details.components(separatedBy: "private func tooltipHoverTracking").last?
                .components(separatedBy: "private func usablePoints").first
        )
        let historyDetail = try XCTUnwrap(
            details.components(separatedBy: "struct GeekBatteryHistoryHoverDetail").last?
                .components(separatedBy: "struct GeekEnergyModeHoverDetail").first
        )

        XCTAssertFalse(historyCard.contains("showsTooltip: true"))
        XCTAssertTrue(tracking.contains("if showsTooltip {"))
        XCTAssertTrue(tracking.contains("content.onContinuousHover"))
        XCTAssertTrue(details.contains(".allowsHitTesting(showsTooltip)"))
        XCTAssertTrue(historyDetail.contains("showsTooltip: true"))
    }

    func testBatteryChargeScaleKeepsSmallChangesReadableWithoutLeavingPercentBounds() {
        XCTAssertEqual(GeekPowerHistoryScale.chargeBarWidth, 2)
        XCTAssertEqual(
            PowerConnectionTimeline.connectedRuns(
                statuses: [nil, false, true, true, false, true]
            ),
            [2...3, 5...5]
        )

        XCTAssertEqual(GeekPowerHistoryScale.chargeRange(values: []), 0...100)

        XCTAssertEqual(
            GeekPowerHistoryScale.chargeRange(values: [48, 50, 52]),
            0...100
        )
        XCTAssertEqual(GeekPowerHistoryScale.connectionTimelineHeight, 4)
        XCTAssertEqual(GeekPowerHistoryScale.connectionTimelineGap, 4)
        XCTAssertEqual(GeekPowerHistoryScale.lightningBoltHeight, 10)
    }

#if DEBUG
    func testBatteryDisplayPreservesMissingAndTrailingBucketsAndUnknownPowerSource() {
        let start = Date(timeIntervalSinceReferenceDate: 28_000)
        let duration: TimeInterval = 30
        let plot = CGRect(x: 0, y: 0, width: 30, height: 90)
        let slotCount = GeekChartWindow.barSlotCount(in: plot)
        let slotDuration = duration / Double(slotCount)
        let samples: [(date: Date, level: Double, source: BatteryPowerSource)] = [
            (
                start.addingTimeInterval(slotDuration * 0.5),
                60,
                .batteryPower
            ),
            (
                start.addingTimeInterval(slotDuration * 1.5),
                60.5,
                .unknown
            ),
            (
                start.addingTimeInterval(slotDuration * 2.5),
                61,
                .acPower
            ),
        ]
        let buckets = GeekChartWindow.barBucketSnapshots(
            for: samples.map(\.date),
            in: plot,
            range: (start, start.addingTimeInterval(duration), start)
        )
        let levels = TimeBucketAggregator.nearestFilled(
            buckets.map { bucket -> Double? in
                guard let index = bucket.indices.last else { return nil }
                return samples[index].level
            }
        )
        let sources = TimeBucketAggregator.forwardFilled(
            buckets.map { bucket -> BatteryPowerSource? in
                guard let index = bucket.indices.last else { return nil }
                let source = samples[index].source
                return source == .unknown ? nil : source
            }
        )

        XCTAssertEqual(buckets.count, slotCount)
        XCTAssertEqual(levels.compactMap(\.value), [60, 60.5, 61])
        XCTAssertEqual(sources.compactMap(\.value), [.batteryPower, .acPower])
        XCTAssertEqual(levels[1].value, 60.5)
        XCTAssertFalse(levels[1].isEstimated)
        XCTAssertNil(sources[1].value)
        XCTAssertFalse(sources[1].isEstimated)
        XCTAssertNil(levels.last?.value)
        XCTAssertNil(sources.last?.value)
        XCTAssertTrue(levels.allSatisfy { !$0.isEstimated })
        XCTAssertTrue(sources.allSatisfy { !$0.isEstimated })

        let connectedRuns = PowerConnectionTimeline.connectedRuns(
            statuses: sources.map { $0.value == .acPower }
        )
        XCTAssertEqual(connectedRuns, [2...2])
    }

    func testBatteryPowerTransitionsWaitForTheFirstRealNewStateBucket() throws {
        let start = Date(timeIntervalSinceReferenceDate: 29_000)
        let duration: TimeInterval = 30
        let plot = CGRect(x: 0, y: 0, width: 30, height: 90)
        let slotCount = GeekChartWindow.barSlotCount(in: plot)
        let slotDuration = duration / Double(slotCount)
        let transitionSlot = 7
        let dates = [1, transitionSlot].map {
            start.addingTimeInterval((Double($0) + 0.5) * slotDuration)
        }
        let buckets = GeekChartWindow.barBucketSnapshots(
            for: dates,
            in: plot,
            range: (start, start.addingTimeInterval(duration), start)
        )
        let rail = CGRect(x: plot.minX, y: plot.maxY + 4, width: plot.width, height: 4)

        let transitions: [(BatteryPowerSource, BatteryPowerSource)] = [
            (.batteryPower, .acPower),
            (.acPower, .batteryPower),
        ]
        for (oldSource, newSource) in transitions {
            let samples = [oldSource, newSource]
            let sources = TimeBucketAggregator.forwardFilled(
                buckets.map { bucket -> BatteryPowerSource? in
                    guard let index = bucket.indices.last else { return nil }
                    return samples[index]
                }
            )
            let statuses = sources.map { $0.value == BatteryPowerSource.acPower }
            let run = try XCTUnwrap(
                PowerConnectionTimeline.connectedRuns(statuses: statuses).first
            )
            let segment = try XCTUnwrap(
                PowerConnectionTimeline.segment(
                    for: run,
                    in: buckets,
                    barWidth: GeekPowerHistoryScale.chargeBarWidth,
                    rail: rail
                )
            )

            XCTAssertNil(sources[transitionSlot - 1].value)
            XCTAssertEqual(sources[transitionSlot].value, newSource)
            XCTAssertFalse(sources[transitionSlot].isEstimated)
            if newSource == .acPower {
                XCTAssertEqual(run, transitionSlot...transitionSlot)
                XCTAssertEqual(
                    segment.minX,
                    buckets[transitionSlot].x - GeekPowerHistoryScale.chargeBarWidth / 2,
                    accuracy: 0.001
                )
            } else {
                XCTAssertEqual(run, 1...1)
                XCTAssertEqual(
                    segment.maxX,
                    buckets[1].x + GeekPowerHistoryScale.chargeBarWidth / 2,
                    accuracy: 0.001
                )
            }
        }
    }

    func testBatteryRecentWindowKeepsTheSharedClockAsItsRightEdge() throws {
        let referenceDate = Date(timeIntervalSinceReferenceDate: 40_000)
        let measuredDate = referenceDate.addingTimeInterval(-12)
        let plot = CGRect(x: 0, y: 0, width: 60, height: 90)
        let range = GeekChartWindow.barRange(
            for: [measuredDate],
            duration: 60,
            referenceDate: referenceDate
        )

        XCTAssertEqual(range.end, referenceDate)

        let buckets = GeekChartWindow.barBucketSnapshots(
            for: [measuredDate],
            in: plot,
            range: range,
            referenceDate: referenceDate
        )
        let levels = TimeBucketAggregator.nearestFilled(
            buckets.map { bucket -> Double? in
                bucket.indices.isEmpty ? nil : 76
            }
        )

        let lastBucket = try XCTUnwrap(buckets.last)
        let lastLevel = try XCTUnwrap(levels.last)
        XCTAssertEqual(lastBucket.end, referenceDate)
        XCTAssertNil(lastLevel.value)
        XCTAssertFalse(lastLevel.isEstimated)
        XCTAssertEqual(
            levels.compactMap { $0.isEstimated ? nil : $0.value },
            [76]
        )
    }

    @MainActor
    func testBatteryRecentWindowRejectsAndClampsFutureSamplesAgainstTheSharedClock() {
        let referenceDate = Date(timeIntervalSinceReferenceDate: 50_000)
        let chart = GeekPowerHistoryChart(
            points: [
                MenuBarPowerHistoryPoint(
                    date: referenceDate.addingTimeInterval(-61),
                    chargePercent: 59,
                    batteryPowerWatts: nil
                ),
                MenuBarPowerHistoryPoint(
                    date: referenceDate.addingTimeInterval(-30),
                    chargePercent: 60,
                    batteryPowerWatts: nil
                ),
                MenuBarPowerHistoryPoint(
                    date: referenceDate.addingTimeInterval(1),
                    chargePercent: 61,
                    batteryPowerWatts: nil
                ),
                MenuBarPowerHistoryPoint(
                    date: referenceDate.addingTimeInterval(3),
                    chargePercent: 62,
                    batteryPowerWatts: nil
                ),
            ],
            metric: .charge,
            duration: 60,
            tint: .blue,
            accessibilityLabel: "Battery"
        )

        let points = chart.usablePoints(endingAt: referenceDate)

        XCTAssertEqual(points.map(\.date), [
            referenceDate.addingTimeInterval(-30),
            referenceDate,
        ])
        XCTAssertEqual(points.map(\.value), [60, 61])
    }

    func testChargeBucketsShareColumnAndTimelineGeometryAcrossPowerTransitions() throws {
        let plot = CGRect(x: 0, y: 0, width: 287, height: 90)
        let referenceDate = MiniWindowDemoData.referenceDate

        for state in [
            MiniWindowDemoData.BatteryDemoState.batteryToExternal,
            .externalToBattery,
        ] {
            let points = MiniWindowDemoData.powerHistory(for: state)
            let chartPoints = points.filter { $0.chargePercent != nil }
            let range = GeekChartWindow.barRange(
                for: chartPoints.map(\.date),
                duration: GeekChartRange.oneHour.duration,
                referenceDate: referenceDate
            )
            let buckets = GeekChartWindow.barBucketSnapshots(
                for: chartPoints.map(\.date),
                in: plot,
                range: range,
                referenceDate: referenceDate
            )
            let preparedSources = TimeBucketAggregator.forwardFilled(
                buckets.map { bucket -> BatteryPowerSource? in
                    guard let index = bucket.indices.last else { return nil }
                    let source = chartPoints[index].powerSource ?? .unknown
                    return source == .unknown ? nil : source
                }
            )
            let statuses = preparedSources.map { prepared -> Bool? in
                switch prepared.value ?? .unknown {
                case .acPower: true
                case .batteryPower: false
                case .unknown: nil
                }
            }
            let rail = CGRect(x: plot.minX, y: plot.maxY + 4, width: plot.width, height: 4)

            for run in PowerConnectionTimeline.connectedRuns(statuses: statuses) {
                let segment = try XCTUnwrap(
                    PowerConnectionTimeline.segment(
                        for: run,
                        in: buckets,
                        barWidth: GeekPowerHistoryScale.chargeBarWidth,
                        rail: rail
                    )
                )
                XCTAssertEqual(
                    segment.minX,
                    buckets[run.lowerBound].x - GeekPowerHistoryScale.chargeBarWidth / 2,
                    accuracy: 0.001
                )
                XCTAssertEqual(
                    segment.maxX,
                    buckets[run.upperBound].x + GeekPowerHistoryScale.chargeBarWidth / 2,
                    accuracy: 0.001
                )
            }
        }

        let sameBucketDates = [
            referenceDate.addingTimeInterval(-10),
            referenceDate.addingTimeInterval(-5),
        ]
        let range = GeekChartWindow.barRange(
            for: sameBucketDates,
            duration: GeekChartRange.oneHour.duration,
            referenceDate: referenceDate
        )
        let sameBucket = try XCTUnwrap(
            GeekChartWindow.barBucketSnapshots(
                for: sameBucketDates,
                in: plot,
                range: range,
                referenceDate: referenceDate
            ).first { !$0.indices.isEmpty }
        )
        let levels: [Double] = [54, 55]
        XCTAssertEqual(
            TimeBucketAggregator.lastValid(sameBucket.indices.map { levels[$0] }),
            55
        )

        let missing = MiniWindowDemoData.powerHistory(for: .missing)
        XCTAssertTrue(missing.compactMap(\.chargePercent).isEmpty)
        XCTAssertTrue(
            PowerConnectionTimeline.connectedRuns(
                statuses: missing.compactMap(\.chargePercent).map { _ in true }
            ).isEmpty
        )
    }
#endif

    func testFanModeUsesSingleChoiceControlsWithoutFakeManualAccess() throws {
        XCTAssertEqual(
            GeekFanControlMode.systemAutomatic.title,
            L10n.text("自动", "Automatic")
        )
        XCTAssertEqual(
            GeekFanControlMode.customCurve.title,
            L10n.text("自定义风扇曲线", "Custom Fan Curve")
        )
        XCTAssertEqual(
            GeekFanControlMode.manual.title,
            L10n.text("手动转速", "Manual RPM")
        )
        XCTAssertEqual(
            GeekFanControlMode.maximum.title,
            L10n.text("最大转速", "Maximum RPM")
        )

        let unsupported = HardwareFanCapabilityProbe.probe(
            fanReadings: [],
            temperatureReadings: [],
            hasTrustedHelper: true,
            observedMode: .manual
        )
        XCTAssertNil(unsupported.observedMode)
        XCTAssertEqual(
            GeekFanControlAvailability.availableModes(capability: unsupported),
            [.systemAutomatic]
        )
        let writable = HardwareFanCapabilityProbe.probe(
            fanReadings: [SystemFanReading(
                index: 0,
                actualRPM: 2_500,
                minimumRPM: 2_000,
                maximumRPM: 6_000,
                targetRPM: 2_500
            )],
            temperatureReadings: [
                SystemTemperatureReading(zone: .chip, celsius: 55),
            ],
            hasTrustedHelper: true,
            observedMode: .manual
        )
        XCTAssertEqual(writable.observedMode, .manual)
        XCTAssertEqual(
            GeekFanControlAvailability.availableModes(capability: writable),
            [.systemAutomatic, .customCurve, .manual, .maximum]
        )

        let sensors = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift"
        )
        let palette = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift"
        )
        let paletteCoordinator = try source(
            "Sources/StorageCleanerMac/Support/ControlPaletteCoordinator.swift"
        )
        let controls = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHardwareControlView.swift"
        )
        let overview = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        XCTAssertFalse(sensors.contains("GeekFanControlCard("))
        XCTAssertFalse(sensors.contains("GeekHardwareAuthorizationCard("))
        XCTAssertFalse(sensors.contains("GeekPowerModeControlCard("))
        XCTAssertTrue(sensors.contains("geekHardwareControlSummaryCard"))
        XCTAssertTrue(sensors.contains("ControlPaletteHoverAnchor("))
        XCTAssertFalse(sensors.contains("struct GeekFanControlHoverDetail"))
        XCTAssertFalse(sensors.contains("当前硬件模式未确认"))
        XCTAssertTrue(sensors.contains("FanStatusPresentation.controlTitle(geekFanControlCapabilityState)"))
        XCTAssertTrue(sensors.contains("selectedFanIndex: reading.index"))
        XCTAssertFalse(overview.contains("case .controllable: L10n.text(\"模式未知\""))
        XCTAssertTrue(sensors.contains("FanControlMode.resolve(observedMode:"))
        XCTAssertTrue(sensors.contains("FanStatusPresentation.confirmedModeTitle(fanControl.observedMode)"))
        // One readout format across overview, secondary ring and lists.
        XCTAssertTrue(overview.contains("value: geekFanTelemetry.actualRPM.map(SystemFanSpeedFormat.number)"))
        XCTAssertFalse(overview.contains("? \"RPM\" :"))
        XCTAssertTrue(sensors.contains("Text(reading.displayRPM)"))
        XCTAssertTrue(controls.contains("ControlPaletteAnchorButton(kind: .fan,")) // D73: the live entry replaces the retired card.
        // D152: the palette's switches show the selection, as iStat's do; the
        // confirmed mode stays the entry row's status, read from observedMode
        // (was the palette's own
        // FanStatusPresentation.confirmedModeTitle(fanControl.observedMode)).
        XCTAssertFalse(palette.contains("FanStatusPresentation.confirmedModeTitle(fanControl.observedMode)"))
        let entryPresentation = try r2SourceDeclaration("struct FanControlEntryPresentation", in: controls)
        XCTAssertTrue(entryPresentation.contains("switch observedMode {"))
        XCTAssertFalse(palette.contains("状态未知"))
        XCTAssertFalse(overview.contains("L10n.text(\"连接中断\", \"Disconnected\")"))
        XCTAssertFalse(overview.contains("return fanControl.selectedMode.title"))
        // D152: one text section per visible mode in iStat's order, our
        // Maximum last (was fanModeSection(.systemAutomatic …) and
        // fanModeSection(.manual …) with displayedMode == .customCurve).
        let fanPalette = try r2SourceDeclaration("struct FanControlPaletteView:", in: palette)
        XCTAssertTrue(fanPalette.contains("ForEach(sections) { choice in"))
        XCTAssertTrue(fanPalette.contains("FanControlPaletteAvailability.visibleModes(telemetry: telemetry)"))
        XCTAssertFalse(palette.contains("fanModeSection("))
        // D64 removed the palette's title icon; D152 removes the title and the
        // capability disclosure, which iStat's fan submenu does not have (was
        // the 风扇控制 title in captionStrong and the 风扇详细信息 button
        // toggling showsCapabilityDetails in paletteContent).
        XCTAssertTrue(fanPalette.contains("if telemetry.isFanless {"))
        XCTAssertFalse(fanPalette.contains("paletteContent"))
        XCTAssertFalse(fanPalette.contains("GeekModuleIcon("))
        XCTAssertFalse(fanPalette.contains("showsCapabilityDetails"))
        XCTAssertFalse(fanPalette.contains("风扇详细信息"))
        XCTAssertFalse(palette.contains("Text(L10n.text(\"风扇控制\", \"Fan Control\"))"))
        let panelComponents = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift"
        )
        let moduleIcon = try r2SourceDeclaration("struct GeekModuleIcon: View", in: panelComponents)
        XCTAssertTrue(moduleIcon.contains(
            "AppSymbolGlyph(systemImage: systemImage, size: MiniWindowStyleTokens.moduleIconGlyphSize)"
        ))
        XCTAssertTrue(moduleIcon.contains(".frame(width: MiniWindowStyleTokens.moduleIconSlotSize,"))
        XCTAssertTrue(moduleIcon.contains("height: MiniWindowStyleTokens.moduleIconSlotSize)"))
        XCTAssertTrue(moduleIcon.contains(".accessibilityHidden(true)"))
        XCTAssertEqual(MiniWindowStyleTokens.moduleIconGlyphSize, 12)
        XCTAssertEqual(MiniWindowStyleTokens.moduleIconSlotSize, 16)
        // D152: each mode is iStat's switch on its section's major label; a
        // switch chooses at once, the one that is on does nothing (were
        // FanControlModeCard with a round mark, a selection that edited the
        // draft through draft.selectMode(mode), and displayedMode reading
        // draft.mode).
        XCTAssertFalse(palette.contains("FanControlModeCard("))
        XCTAssertFalse(palette.contains(".fill(selected ? controlTint : Color.secondary.opacity(0.32))"))
        XCTAssertTrue(fanPalette.contains(".toggleStyle(GeekIStatSwitchToggleStyle())"))
        XCTAssertFalse(palette.contains("draft.selectMode(mode)"))
        XCTAssertTrue(fanPalette.contains("await fanControl.selectMode(mode)"))
        XCTAssertFalse(palette.contains(
            "fanControl.selectedMode == .systemAutomatic ? .systemAutomatic : nil"
        ))
        XCTAssertFalse(palette.contains("private var displayedMode: GeekFanControlMode? { draft.mode }"))
        XCTAssertTrue(fanPalette.contains(
            "Self.displayedMode(requested: fanControl.requestedMode, selected: fanControl.selectedMode)"
        ))
        XCTAssertFalse(palette.contains("Toggle(\"\", isOn: .constant"))
        // D152 (F6): the curve is edited in Settings and on the fan-curve
        // detail; the curve's switch applies it (was
        // palette.contains("FanCurveEditor(")).
        XCTAssertFalse(palette.contains("FanCurveEditor("))
        XCTAssertTrue(fanPalette.contains("await fanControl.applyFanCurveDraft()"))
        XCTAssertTrue(palette.contains("if fanControl.helperState != .enabled"))
        // D152 (F4, as iStat): a drag stores the value and the coordinator
        // writes it 0.2 s after the last move; a press beside the knob, the
        // release or a VoiceOver step writes at once. No draft and no Apply
        // (was: pointer and accessibility changes edited the local draft
        // through draft.setPercentage, and only Apply's
        // submitted.submit(to: fanControl …) reached the coordinator).
        let sharedControls = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/FanControlInlineControls.swift"
        )
        XCTAssertTrue(palette.contains("FanManualSliderList("))
        // D152: Sync is iStat's tick row in the manual section, once, outside
        // the slider list (was FanSyncToggleRow, the only switch, inside the
        // list; U1 117/118, D44, D45).
        XCTAssertFalse(sharedControls.contains("FanSyncToggleRow"))
        XCTAssertEqual(fanPalette.components(separatedBy: "GeekIStatTickRow(").count - 1, 1)
        let manualList = try r2SourceDeclaration("struct FanManualSliderList: View", in: sharedControls)
        XCTAssertFalse(manualList.contains("GeekIStatTickRow("))
        // Review r3 P1-1: the slider is the drag and VoiceOver path, so it stays under this contract.
        let sliderView = try r2SourceDeclaration("struct FanControlSlider", in: sharedControls)
        XCTAssertTrue(manualList.contains("onDrag: { fanControl.updateManualPercentage($0 * 100, fanID: slider.fanID) }"))
        XCTAssertTrue(manualList.contains("onCommit: { fanControl.commitManualPercentage($0 * 100, fanID: slider.fanID) }"))
        XCTAssertFalse(sliderView.contains("fanControl."), "The slider reports; its list writes through the coordinator")
        XCTAssertFalse(sharedControls.contains("draft.setPercentage"))
        XCTAssertFalse(palette.contains("submitted.submit(to: fanControl"))
        // D152: the step is ignored while disabled (was `guard !isDisabled`).
        XCTAssertTrue(sharedControls.contains(".accessibilityAdjustableAction { direction in\n            guard isEnabled else { return }"))
        // AppKit's NSSlider (behind SwiftUI's Slider) blocks the MainActor in
        // its event-tracking loop while dragging, starving lease renewals
        // until the helper watchdog reverts manual mode. The gesture-driven
        // slider keeps the run loop alive for the whole drag.
        XCTAssertTrue(sharedControls.contains("FanControlSlider"))
        XCTAssertTrue(sharedControls.contains("DragGesture(minimumDistance: 0)"))
        XCTAssertTrue(sharedControls.contains("accessibilityAdjustableAction"))
        // D152: iStat's 30 pt slider (was a 22 pt row, with the sync switch
        // tinted Palette.information while on).
        XCTAssertTrue(sharedControls.contains(".frame(height: Geometry.height)"))
        XCTAssertEqual(FanControlSliderGeometry.height, 30)
        XCTAssertFalse(sharedControls.contains("AppDesignTokens.Palette.information"))
        XCTAssertFalse(sharedControls.contains("            Slider("))
        // D152: iStat's Sync label (was 同步所有风扇).
        XCTAssertFalse(sharedControls.contains("同步所有风扇"))
        XCTAssertTrue(fanPalette.contains("title: L10n.text(\"同步\", \"Sync\"),"))
        XCTAssertFalse(palette.contains("isAutomatic: Bool"))
        XCTAssertFalse(palette.contains("isCurve: Bool"))
        XCTAssertFalse(palette.contains("isManual: Bool"))
        // D152: a switch is identified by its mode (was
        // .accessibilityIdentifier(title) on the cards).
        XCTAssertTrue(fanPalette.contains(".accessibilityIdentifier(\"fan-mode-\" + choice.mode.rawValue)"))
        XCTAssertTrue(paletteCoordinator.contains(
            ".accessibilityIdentifier(accessibilityLabel)"
        ))
    }

    /// Monitoring and control are separate surfaces (the iStat model). The
    /// sensors card only reads fan state; every mode switch and slider lives
    /// in the attached palette. A rebuilt segmented control inside the
    /// reflowing monitoring card once fired a spurious "automatic" selection
    /// and silently reverted manual mode — no control may return there.
    func testSensorsPageSeparatesFanMonitoringFromControl() throws {
        let sensors = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift"
        )

        // Read-only monitoring rows open the shared controls on hover; opening never submits.
        XCTAssertTrue(sensors.contains("compactFanHistoryRow"))
        XCTAssertTrue(sensors.contains("geekFanThermallyProtected"))
        XCTAssertTrue(sensors.contains("ControlPaletteHoverAnchor("))
        // D119 (2026-10-18): the thermal state is a warning-tinted row of the
        // fan group and the helper action the title row's text (was a capsule).
        XCTAssertFalse(sensors.contains("MiniWindowStatusCapsule("))
        XCTAssertTrue(sensors.contains("L10n.text(\"热保护中\", \"Thermal protection\")"))
        XCTAssertTrue(sensors.contains(".geekIStatValueText(AppDesignTokens.Palette.warning)"))
        // D122 (2026-10-18): the page's text is iStat's label and value text;
        // the probe list and the readout pages were its last caption text
        // (was `sensors.contains("AdvancedPanelTypography.caption")`).
        XCTAssertTrue(sensors.contains(".geekIStatLabelText()"))
        // No state-changing controls on monitoring surfaces.
        XCTAssertFalse(sensors.contains("FanModeSegmentedPicker"))
        XCTAssertFalse(sensors.contains("FanManualSliderList"))
        XCTAssertFalse(sensors.contains("fanControl.selectMode"))
        XCTAssertFalse(sensors.contains("Picker("))
    }

    func testSensorAndPowerCardsExposeContextualHoverDetailsWithoutNewSamplingInfrastructure() throws {
        let sensors = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift")
        let overview = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        let power = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift")
        let details = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        let tertiary = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let models = try source("Sources/StorageCleanerMac/Models/FanControlModels.swift")

        XCTAssertGreaterThanOrEqual(
            sensors.components(separatedBy: "GeekHoverDetailTarget(").count - 1,
            4
        )
        XCTAssertEqual(power.components(separatedBy: "GeekHoverDetailTarget(").count - 1, 2)
        XCTAssertTrue(sensors.contains("ControlPaletteHoverAnchor("))
        XCTAssertTrue(power.contains("ControlPaletteHoverAnchor("))
        XCTAssertTrue(sensors.contains("FanTelemetryState.resolve(snapshot:"))
        XCTAssertTrue(details.contains("reading.minimumRPM"))
        XCTAssertTrue(details.contains("reading.maximumRPM"))
        XCTAssertTrue(details.contains("reading.targetRPM"))
        XCTAssertFalse(details.contains("electrical?.designCapacityMAh"))
        XCTAssertFalse(details.contains("electrical?.currentCapacityMAh"))
        XCTAssertTrue(details.contains("electrical?.adapterPowerWatts"))
        XCTAssertFalse(details.contains("electrical?.powerWatts"))
        XCTAssertFalse(details.contains("maximumCapacityValue"))
        XCTAssertFalse(details.contains(".help(statisticsHelpText)"))
        XCTAssertTrue(details.contains(".accessibilityHint(helpText(statistics: statistics))"))
        XCTAssertTrue(details.contains("PanelChartSamplingPlaceholder()"))
        XCTAssertFalse(details.contains("能源模式未采集，选项不可用"))
        // D64 removes the uncalled GeekEnergyModeOptionRow. The live group
        // uses native segments and a source-aware binding instead.
        // D124: iStat's energy-mode menu, the supported modes as tick rows in
        // the menu's order, the check on the store's reading (were native
        // segments bound to it).
        let energy = try r2SourceDeclaration("private struct GeekEnergyModeGroup:", in: details)
        XCTAssertTrue(energy.contains("GeekIStatTickRow("))
        XCTAssertFalse(energy.contains("MiniWindowSegmentedPicker("))
        XCTAssertTrue(energy.contains("title: title"))
        XCTAssertTrue(energy.contains("isSelected: selected == mode"))
        XCTAssertTrue(energy.contains("BatteryPowerMode.energyMenuOrder(supportedModes)"))
        XCTAssertFalse(energy.contains("@State"), "the selection is the reading, never a local draft")
        XCTAssertTrue(energy.contains("onChangeMode(source, selected)"))
        XCTAssertTrue(energy.contains(".disabled(!controlsEnabled || adjustmentState.isChanging)"))
        XCTAssertTrue(energy.contains(".help(statusText ?? L10n.text("))
        let segments = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MiniWindowSegmentedPicker.swift")
        XCTAssertTrue(segments.contains("control.setAccessibilityLabel(title)"))
        XCTAssertTrue(segments.contains("control.selectedSegment = options.firstIndex(of: selection)"))
        XCTAssertTrue(details.contains("System control setup was cancelled"))
        XCTAssertTrue(details.contains("one-time system control approval"))
        XCTAssertTrue(energy.contains("Text(statusText)"))
        XCTAssertTrue(energy.contains(".lineLimit(1)"))
        XCTAssertFalse(power.contains("onChangeMode: changeEnergyMode"))
        XCTAssertTrue(power.contains("computerHealthStore.changeBatteryPowerMode("))
        XCTAssertTrue(power.contains("computerHealthStore.refreshBatteryPowerModes()"))
        XCTAssertFalse(power.contains("openEnergyModeSettings"))
        XCTAssertFalse(power.contains("_ = (requestedMode, requestedSource)"))
        XCTAssertFalse(power.contains("sudo"))
        XCTAssertFalse(power.contains("pmset"))

        XCTAssertFalse(sensors.contains("电池与供电"))
        XCTAssertFalse(sensors.contains("BATTERY & SUPPLY"))
        XCTAssertFalse(sensors.contains("电池电气信息"))
        XCTAssertFalse(sensors.contains("geekSensorReadoutCard(L10n.text(\"功耗\""))
        XCTAssertFalse(sensors.contains("geekSensorReadoutCard(L10n.text(\"频率\""))
        XCTAssertFalse(sensors.contains("secondaryTitle: L10n.text(\"频率\""))
        XCTAssertFalse(sensors.contains("detail: geekProcessorFrequencyTextCompact"))
        // D119 (2026-10-18): iStat lists current, power and voltage in the
        // sensors menu, so the battery-electrical and power cards left the
        // power page for the sensors page's groups.
        XCTAssertFalse(power.contains("BATTERY ELECTRICAL"))
        XCTAssertFalse(power.contains("geekBatteryElectricalReadouts"))
        XCTAssertFalse(power.contains("geekPowerReadouts"))
        let processor = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift")
        // D119 (2026-10-18): the cluster frequencies are a group of the
        // sensors page, as on iStat (was a CPU page card).
        XCTAssertFalse(processor.contains("geekFrequencyReadouts"))
        let helperCards = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHelperPowerMetricsCards.swift")
        XCTAssertTrue(helperCards.contains("let rows = geekFrequencyReadouts"))
        XCTAssertTrue(helperCards.contains("let current = geekBatteryCurrentReadouts"))
        XCTAssertTrue(helperCards.contains("let voltage = geekBatteryVoltageReadouts"))
        XCTAssertTrue(helperCards.contains("let readouts = geekPowerReadouts"))
        XCTAssertTrue(sensors.contains("geekHelperPowerMetricsCards"))
        XCTAssertTrue(details.contains("GeekBatteryElectricalHoverDetail"))
        XCTAssertTrue(models.contains("readings.compactMap(\\.normalizedPercent)"))
        XCTAssertTrue(sensors.contains("ForEach(geekFanTelemetry.readings.prefix(2))")) // D73: lock the live monitoring rows.
        XCTAssertTrue(sensors.contains("selectedFanIndex: reading.index"))
        XCTAssertTrue(details.contains("point.fanRPM(at: selectedFanIndex)"))
        XCTAssertTrue(details.contains("GeekHoverDetailCanvas(\n            title: chartTitle,"))
        XCTAssertFalse(details.contains("SystemFanSpeedFormat.string(Int(valueRange.upperBound.rounded()))"))
        XCTAssertFalse(sensors.contains("geekFanNormalizedAveragePercent == nil\n                            ? \"RPM\""))
        XCTAssertFalse(sensors.contains("CPU FREQUENCY"))
        XCTAssertTrue(sensors.contains("geekGPURingDetail"))
        XCTAssertTrue(sensors.contains("L10n.text(\"负载\", \"Load\")"))
        XCTAssertTrue(sensors.contains("if !geekDisplayedTemperatures.isEmpty"))
        XCTAssertTrue(sensors.contains("ForEach(geekDisplayedTemperatures)"))
        XCTAssertFalse(sensors.contains("geekFrequencyClusters"))
        XCTAssertFalse(sensors.contains("geekFrequencyClusters.prefix(3)"))
        XCTAssertTrue(sensors.contains("No sensor readings are available for this Mac"))
        XCTAssertTrue(sensors.contains("L10n.text(\"负载\", \"Load\")"))
        XCTAssertTrue(sensors.contains("L10n.text(\"GPU 温度\", \"GPU Temperature\")"))
        let powerPalette = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift")
        XCTAssertTrue(powerPalette.contains("batterySupportedModes: hasInternalBattery"))
        XCTAssertTrue(details.contains("if !batterySupportedModes.isEmpty")) // D73: no dead power-card contract.
        XCTAssertTrue(overview.contains("value: geekOverviewGPUTemperature.map"))
        XCTAssertTrue(overview.contains("gpuUsageText: metricValue(.gpuUsage)"))
        // Batch 2b removed the unreferenced tile that carried 温度 / Temperature;
        // the live overview GPU ring labels its temperature 温度 / Temp.
        XCTAssertTrue(overview.contains("L10n.text(\"温度\", \"Temp\")"))
        XCTAssertTrue(tertiary.contains("if let gpuTemperature = geekGPUTemperature"))
        XCTAssertTrue(tertiary.contains("title: L10n.text(\"GPU 温度\", \"GPU Temperature\")"))
        XCTAssertTrue(sensors.contains("return orderedZones.filter(available.contains)"))
        XCTAssertFalse(sensors.contains("Missing values stay visibly unavailable"))
        // D119 (2026-10-18): a temperature row is iStat's 12 pt label and
        // value (was the 11 pt grid font).
        let temperatureRow = try XCTUnwrap(
            sensors.components(separatedBy: "private func geekTemperatureRowContent(").last?
                .components(separatedBy: "private func geekTemperatureZoneTitle(").first
        )
        XCTAssertTrue(temperatureRow.contains(".geekIStatLabelText()"))
        XCTAssertTrue(temperatureRow.contains(".geekIStatValueText(geekTemperatureValueForeground(reading.celsius))"))
        XCTAssertTrue(temperatureRow.contains("minHeight: GeekIStatSectionGeometry.rowHeight"))
        // D119: the power and current groups are on the sensors page, built
        // beside the helper rows (they were power-page cards titled
        // 功耗 and AMPERAGE).
        XCTAssertFalse(sensors.contains("L10n.text(\"电流\", \"AMPERAGE\")"))
        // D138: the group takes iStat's name, 'Sensors.Amperage' (AMPERAGE);
        // the power page's old AMPERAGE card stays gone (were
        // `XCTAssertFalse(helperCards.contains("AMPERAGE"))` and the title CURRENT).
        XCTAssertEqual(helperCards.components(separatedBy: "AMPERAGE").count - 1, 1)
        XCTAssertFalse(power.contains("AMPERAGE"))
        XCTAssertTrue(helperCards.contains("geekSensorReadoutCard(L10n.text(\"电流\", \"AMPERAGE\"), rows: current)"))
        XCTAssertTrue(helperCards.contains("geekSensorReadoutCard(L10n.text(\"功率\", \"POWER\")"))
        XCTAssertTrue(helperCards.contains("geekSensorReadoutCard(L10n.text(\"电压\", \"VOLTAGE\"), rows: voltage)"))

        let powerSources = power + details
        XCTAssertFalse(powerSources.contains("channel: .memory"))
        XCTAssertFalse(powerSources.contains("Timer("))
        XCTAssertFalse(powerSources.contains("NSPanel"))
        XCTAssertFalse(powerSources.contains("NSWindow("))
    }

    func testSelectedFanHistoryKeepsHardwareBoundsAndDoesNotInventMissingTarget() throws {
        let stopped = SystemFanReading(
            index: 0, actualRPM: 0, minimumRPM: 0, maximumRPM: 6_000, targetRPM: nil
        )
        XCTAssertEqual(GeekFanHoverDetail.rangeValues(for: stopped), [
            SystemFanSpeedFormat.string(0), SystemFanSpeedFormat.string(6_000), "—",
        ])
        XCTAssertEqual(GeekFanHoverDetail.rangeValues(for: nil), ["—", "—", "—"])
        let zeroTarget = SystemFanReading(
            index: 1, actualRPM: 0, minimumRPM: nil, maximumRPM: nil, targetRPM: 0
        )
        XCTAssertEqual(GeekFanHoverDetail.rangeValues(for: zeroTarget), ["—", "—", SystemFanSpeedFormat.string(0)])

        let details = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        let fanStart = try XCTUnwrap(details.range(of: "struct GeekFanHoverDetail")).lowerBound
        let fanEnd = try XCTUnwrap(details.range(of: "struct GeekBatteryElectricalHoverDetail")).lowerBound
        let fanDetail = String(details[fanStart..<fanEnd])
        XCTAssertTrue(fanDetail.contains("if selectedFanIndex != nil"))
        XCTAssertTrue(fanDetail.contains("trailing: currentValue"))
        XCTAssertTrue(fanDetail.contains("accessibilityLabel: chartTitle"))

        let sensors = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift")
        let presentationStart = try XCTUnwrap(sensors.range(of: "struct GeekSensorFanRingPresentation")).lowerBound
        let ringStart = try XCTUnwrap(sensors.range(of: "struct GeekSensorFanRing: View")).lowerBound
        let ringEnd = try XCTUnwrap(sensors.range(of: "enum GeekSensorPageAvailability")).lowerBound
        let presentation = String(sensors[presentationStart..<ringStart])
        let ring = String(sensors[ringStart..<ringEnd])
        XCTAssertTrue(presentation.contains("else if let rpm = telemetry.actualRPM"))
        XCTAssertTrue(presentation.contains("SystemFanSpeedFormat.number(rpm)"))
        XCTAssertFalse(presentation.contains("percentage"))
        XCTAssertTrue(sensors.contains("GeekSensorFanRing(telemetry: geekFanTelemetry"))
        XCTAssertTrue(ring.contains("value: presentation.value"))
        XCTAssertTrue(ring.contains("detail: presentation.caption"))
        XCTAssertTrue(ring.contains("progress: telemetry.percentage.map { $0 / 100 }"))
        let stoppedTelemetry = FanTelemetryState(actualRPM: 0, minRPM: 0, maxRPM: 6_000,
            targetRPM: nil, fanCount: 1, timestamp: nil, telemetryAvailable: true,
            isSampling: false, isFanless: false, readings: [stopped])
        let stoppedRing = GeekSensorFanRingPresentation(telemetry: stoppedTelemetry)
        XCTAssertEqual(stoppedRing.value, SystemFanSpeedFormat.number(0))
        XCTAssertEqual(stoppedRing.caption, "rpm")
        XCTAssertEqual(stoppedTelemetry.percentage, 0)
        let unknownTelemetry = FanTelemetryState(actualRPM: nil, minRPM: nil, maxRPM: nil,
            targetRPM: nil, fanCount: 0, timestamp: nil, telemetryAvailable: false,
            isSampling: false, isFanless: false, readings: [])
        let unknownRing = GeekSensorFanRingPresentation(telemetry: unknownTelemetry)
        XCTAssertEqual(unknownRing.value, "—")
        XCTAssertEqual(unknownRing.caption, L10n.text("不可用", "N/A"))
        XCTAssertNil(unknownTelemetry.percentage)
        // D152: iStat's manual section has no presets. A disabled slider
        // ignores gestures and VoiceOver steps, and a preview disables the
        // list (were the 25/50/75/100 % presets, disabled with the list,
        // editing the draft through draft.setPercentage(preset, fanID: nil)
        // and never committing).
        let manual = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/FanControlInlineControls.swift")
        XCTAssertFalse(manual.contains("ForEach([25.0, 50.0, 75.0, 100.0]"))
        let sliderSource = try r2SourceDeclaration("struct FanControlSlider", in: manual)
        // D152 tracking: iStat's mouse handling is FanControlSliderGeometry.
        // Tracking (behaviour in MiniWindowIStatFanControlTests); the view
        // drops a step and the release's write while disabled (was
        // `guard isEnabled, !ignoresGesture else { return }` in the view).
        XCTAssertTrue(sliderSource.contains(".onChanged { step in\n                        guard isEnabled else { return }"))
        XCTAssertTrue(sliderSource.contains("let writes = tracking.ended()\n                        guard isEnabled else { return }"))
        XCTAssertTrue(sliderSource.contains(".allowsHitTesting(isEnabled)"))
        XCTAssertTrue(sliderSource.contains("            guard isEnabled else { return }"))
        // The view hit-tests the knob at the stored value and hands each
        // write to its callback: a drag step to onDrag (written after the
        // debounce), a press beside the knob and the release to onCommit (at
        // once); a VoiceOver step writes at once.
        XCTAssertTrue(sliderSource.contains("width: width, stored: fraction))"))
        XCTAssertTrue(sliderSource.contains("case .drag(let value): onDrag(value)"))
        XCTAssertTrue(sliderSource.contains("case .commit(let value): onCommit(value)"))
        XCTAssertTrue(sliderSource.contains("case .increment: onCommit(min(1, value + Geometry.accessibilityStep))"))
        XCTAssertTrue(sliderSource.contains("case .decrement: onCommit(max(0, value - Geometry.accessibilityStep))"))
        let paletteSource = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift")
        XCTAssertTrue(paletteSource.contains(
            "FanManualSliderList(fanControl: fanControl, readings: telemetry.readings)\n                .disabled(fanControl.isDataOnlyFixture)"
        ))
        // A section's switch is on for the mode being set up or set
        // (displayedMode); it chooses only a mode that is off and available,
        // the curve's switch applies the curve Settings or the fan-curve page
        // left and the others select their mode.
        XCTAssertTrue(paletteSource.contains("get: { displayedMode == choice.mode },"))
        XCTAssertTrue(paletteSource.contains("guard mode != displayedMode, disabledReason(mode) == nil else { return }"))
        XCTAssertTrue(paletteSource.contains(
            "if mode == .customCurve {\n                await fanControl.applyFanCurveDraft()\n            } else {\n                await fanControl.selectMode(mode)\n            }"
        ))
    }

    func testFanMiniRingUsesRealNormalizedRange() {
        let reading = SystemFanReading(
            index: 0,
            actualRPM: 3_000,
            minimumRPM: 1_000,
            maximumRPM: 5_000,
            targetRPM: 3_100
        )

        XCTAssertEqual(reading.normalizedPercent, 50)
    }

    func testPowerPageReusesExistingHealthRefreshPathWithoutNewSampler() throws {
        let power = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift")
        let sharedActions = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift")
        let panel = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")

        XCTAssertTrue(power.contains("await computerHealthStore.refresh()"))
        XCTAssertTrue(panel.contains("await computerHealthStore.refreshBatteryPowerModes()"))
        XCTAssertTrue(sharedActions.contains("await computerHealthStore.refresh(force: true)"))
        XCTAssertFalse(power.contains("Timer("))
        XCTAssertFalse(panel.contains("Timer("))
        XCTAssertFalse(sharedActions.contains("Timer("))
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try r2ProductionSource(at: projectRoot.appendingPathComponent(relativePath))
    }
}
