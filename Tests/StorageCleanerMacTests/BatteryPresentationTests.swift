import XCTest
@testable import StorageCleanerMac

final class BatteryPresentationTests: XCTestCase {
    func testChargeTargetDefaultsTo80AndPersists100() throws {
        let suiteName = "BatteryPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(BatteryChargeTarget.stored(in: defaults), .protected)
        XCTAssertEqual(BatteryChargeTarget.protected.manualLimitPercent, 80)
        XCTAssertNil(BatteryChargeTarget.full.manualLimitPercent)
        BatteryChargeTarget.full.save(in: defaults)
        XCTAssertEqual(BatteryChargeTarget.stored(in: defaults), .full)

        defaults.set(85, forKey: BatteryChargeTarget.defaultsKey)
        XCTAssertEqual(
            BatteryChargeTarget.stored(in: defaults),
            BatteryChargeTarget(rawValue: 85)
        )

        defaults.set(69, forKey: BatteryChargeTarget.defaultsKey)
        XCTAssertEqual(BatteryChargeTarget.stored(in: defaults), .protected)
    }

    func testChargeLimitStateFollowsNativeTargetAndAvailableLimits() throws {
        let limited = try XCTUnwrap(BatteryChargeLimitState.resolve(
            manualLimitEnabled: true,
            manualLimit: 85,
            availableLimits: [100, 80, 85, 90, 95, 85]
        ))
        XCTAssertEqual(limited.target, BatteryChargeTarget(rawValue: 85))
        XCTAssertEqual(limited.availableTargets.map(\.rawValue), [80, 85, 90, 95, 100])

        let full = try XCTUnwrap(BatteryChargeLimitState.resolve(
            manualLimitEnabled: false,
            manualLimit: 80,
            availableLimits: [80, 85, 90, 95, 100]
        ))
        XCTAssertEqual(full.target, .full)

        let futureSeventy = try XCTUnwrap(BatteryChargeLimitState.resolve(
            manualLimitEnabled: true,
            manualLimit: 70,
            availableLimits: [70, 80, 100]
        ))
        XCTAssertEqual(futureSeventy.target.rawValue, 70)
        XCTAssertEqual(futureSeventy.availableTargets.map(\.rawValue), [70, 80, 100])
        XCTAssertNil(BatteryChargeLimitState.resolve(
            manualLimitEnabled: true,
            manualLimit: 69,
            availableLimits: [80, 100]
        ))
    }

    func testMissingChargeLimitFlagCannotBecomeAFullChargeTarget() throws {
        for limit: Int? in [nil, 80, 100] {
            XCTAssertNil(BatteryChargeLimitState.resolve(
                manualLimitEnabled: nil,
                manualLimit: limit,
                availableLimits: [80, 100]
            ))
        }
        XCTAssertEqual(try XCTUnwrap(BatteryChargeLimitState.resolve(
            manualLimitEnabled: false,
            manualLimit: nil,
            availableLimits: [80, 100]
        )).target, .full)
        XCTAssertNil(BatteryChargeLimitState.resolve(
            manualLimitEnabled: true,
            manualLimit: nil,
            availableLimits: [80, 100]
        ))
    }

    func testSystemFactsResolveToExplicitPresentationStates() {
        XCTAssertEqual(
            BatteryPowerSnapshot(
                chargePercent: 63,
                isCharging: true,
                powerSource: .acPower,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: 78
            ).presentationState,
            .charging(timeToFullMinutes: 78)
        )
        XCTAssertEqual(
            BatteryPowerSnapshot(
                chargePercent: 63,
                isCharging: true,
                powerSource: .acPower,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: nil
            ).presentationState,
            .charging(timeToFullMinutes: nil)
        )
        XCTAssertEqual(
            BatteryPowerSnapshot(
                chargePercent: 100,
                isCharging: false,
                powerSource: .acPower,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: nil,
                isFullyCharged: true
            ).presentationState,
            .charged
        )
        XCTAssertEqual(
            BatteryPowerSnapshot(
                chargePercent: 80,
                isCharging: false,
                powerSource: .acPower,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: nil,
                isOptimizedChargingEngaged: true
            ).presentationState,
            .optimizedChargingPaused
        )
        XCTAssertEqual(
            BatteryPowerSnapshot(
                chargePercent: 80,
                isCharging: false,
                powerSource: .acPower,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: nil
            ).presentationState,
            .connectedNotCharging
        )
        XCTAssertEqual(
            BatteryPowerSnapshot(
                chargePercent: 72,
                isCharging: false,
                powerSource: .batteryPower,
                timeToEmptyMinutes: 266,
                timeToFullChargeMinutes: nil
            ).presentationState,
            .discharging(timeToEmptyMinutes: 266)
        )
        XCTAssertEqual(
            BatteryPowerSnapshot(
                chargePercent: 100,
                isCharging: false,
                powerSource: .batteryPower,
                timeToEmptyMinutes: nil,
                timeToFullChargeMinutes: nil
            ).presentationState,
            .discharging(timeToEmptyMinutes: nil)
        )
    }

    func testMissingEstimateAndMissingSampleStayUnavailable() {
        let snapshot = BatteryPowerSnapshot(
            chargePercent: 72,
            isCharging: false,
            powerSource: .batteryPower,
            timeToEmptyMinutes: nil,
            timeToFullChargeMinutes: nil
        )
        XCTAssertEqual(snapshot.presentationState, .discharging(timeToEmptyMinutes: nil))

        let missing = BatterySample(
            timestamp: Date(timeIntervalSince1970: 1),
            monotonicTimestamp: .zero,
            snapshot: nil
        )
        XCTAssertFalse(missing.isValid)

        let point = MenuBarPowerHistoryPoint(
            date: Date(timeIntervalSince1970: 2),
            chargePercent: nil,
            batteryPowerWatts: nil,
            isCharging: nil,
            powerSource: .unknown
        )
        XCTAssertFalse(point.isValid)
    }

    func testFullChargeActionRequiresPausedACBelowFull() {
        XCTAssertTrue(BatteryPowerSnapshot(
            chargePercent: 80,
            isCharging: false,
            powerSource: .acPower,
            timeToEmptyMinutes: nil,
            timeToFullChargeMinutes: nil
        ).shouldOfferFullChargeAction)
        XCTAssertFalse(BatteryPowerSnapshot(
            chargePercent: 80,
            isCharging: true,
            powerSource: .acPower,
            timeToEmptyMinutes: nil,
            timeToFullChargeMinutes: 30
        ).shouldOfferFullChargeAction)
        XCTAssertFalse(BatteryPowerSnapshot(
            chargePercent: 80,
            isCharging: false,
            powerSource: .batteryPower,
            timeToEmptyMinutes: 240,
            timeToFullChargeMinutes: nil
        ).shouldOfferFullChargeAction)
        XCTAssertFalse(BatteryPowerSnapshot(
            chargePercent: 100,
            isCharging: false,
            powerSource: .acPower,
            timeToEmptyMinutes: nil,
            timeToFullChargeMinutes: nil
        ).shouldOfferFullChargeAction)
    }

    func testFullChargePreflightRejectsUnverifiableStates() {
        XCTAssertEqual(BatteryFullChargeService.preflightResult(for: nil), .unsupported)
        XCTAssertEqual(BatteryFullChargeService.preflightResult(for: BatteryPowerSnapshot(
            chargePercent: 80,
            isCharging: false,
            powerSource: .batteryPower,
            timeToEmptyMinutes: 120,
            timeToFullChargeMinutes: nil
        )), .requiresACPower)
        XCTAssertEqual(BatteryFullChargeService.preflightResult(for: BatteryPowerSnapshot(
            chargePercent: 80,
            isCharging: true,
            powerSource: .acPower,
            timeToEmptyMinutes: nil,
            timeToFullChargeMinutes: 30
        )), .alreadyCharging)
        XCTAssertEqual(BatteryFullChargeService.preflightResult(for: BatteryPowerSnapshot(
            chargePercent: 100,
            isCharging: false,
            powerSource: .acPower,
            timeToEmptyMinutes: nil,
            timeToFullChargeMinutes: nil
        )), .alreadyFull)
        XCTAssertNil(BatteryFullChargeService.preflightResult(for: BatteryPowerSnapshot(
            chargePercent: 80,
            isCharging: false,
            powerSource: .acPower,
            timeToEmptyMinutes: nil,
            timeToFullChargeMinutes: nil
        )))
    }

    func testBatteryChartUsesPowerSourceNotChargeSlope() {
        let ac = MenuBarPowerHistoryPoint(
            date: Date(timeIntervalSince1970: 1),
            chargePercent: 60,
            batteryPowerWatts: nil,
            isCharging: false,
            powerSource: .acPower
        )
        let battery = MenuBarPowerHistoryPoint(
            date: Date(timeIntervalSince1970: 2),
            chargePercent: 59,
            batteryPowerWatts: nil,
            isCharging: false,
            powerSource: .batteryPower
        )
        XCTAssertEqual(GeekPowerHistoryMetric.charge.tooltipDetail(isCharging: ac.isCharging, powerSource: ac.powerSource), L10n.text("外接电源", "External power"))
        XCTAssertEqual(GeekPowerHistoryMetric.charge.tooltipDetail(isCharging: battery.isCharging, powerSource: battery.powerSource), L10n.text("使用电池", "Using battery"))
        XCTAssertEqual(GeekPowerHistoryScale.chargeRange(values: [59, 60]), 0...100)
    }

    func testOverviewUsesCompactBatteryTextWhileAccessibilityKeepsTheFullState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let components = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
            ),
            encoding: .utf8
        )
        let panel = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(components.contains("var batteryPresentationStateCompactTitle"))
        XCTAssertTrue(components.contains("约 \\(batteryCompactDurationText(minutes))后充满"))
        XCTAssertTrue(components.contains("剩余约 \\(batteryCompactDurationText(minutes))"))
        XCTAssertTrue(panel.contains("return batteryPresentationStateCompactTitle"))
        XCTAssertTrue(panel.contains("let status = batterySnapshot == nil ? geekOverviewBatteryStatusText : batteryStatusTitle"))
    }

    func testBatterySurfaceKeepsPreviewRangeIndependentFromHistoryRange() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let power = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(power.contains("duration: GeekPowerLayout.detailPreviewDuration"))
        XCTAssertTrue(power.contains("points: batteryPowerHistory"))
        XCTAssertFalse(power.contains("duration: geekChartDuration"))

        let details = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(details.contains("enum PowerConnectionTimeline"))
        XCTAssertTrue(details.contains("GeekChartWindow.displayBuckets("))
        XCTAssertGreaterThanOrEqual(
            details.components(separatedBy: "preparedBatteryBuckets(").count - 1,
            5
        )
        XCTAssertTrue(details.contains("date: prepared.bucket.end"))
        XCTAssertTrue(details.contains(
            "isEstimated: buckets[index].isEstimated || payloads[index].isEstimated\n                    || chargingStates[index].isEstimated\n                    || powerSources[index].isEstimated"
        ))
        XCTAssertTrue(details.contains("isEstimated: hoveredPoint.isEstimated"))
        XCTAssertFalse(details.contains("date: latest.date"))
        XCTAssertFalse(details.contains("date: mark.end"))
    }
}
