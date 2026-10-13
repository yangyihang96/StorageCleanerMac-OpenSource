import IOKit.ps
import XCTest
@testable import StorageCleanerMac

/// The battery status says "正在计算" only while macOS itself is calculating
/// a time: IOPowerSources reports -1 for the valid time key ("Still
/// Calculating the Time"). A full battery, a connected battery that is not
/// charging, a paused optimized charge, a finishing charge and a missing
/// estimate each have their own wording.
@MainActor
final class MiniWindowBatteryStatusTests: XCTestCase {
    private func description(
        source: String,
        charging: Bool?,
        capacity: Int = 100,
        timeToFull: Int? = nil,
        timeToEmpty: Int? = nil,
        charged: Bool? = nil,
        finishing: Bool? = nil,
        optimized: Bool? = nil
    ) -> [String: Any] {
        var description: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSPowerSourceStateKey: source,
            kIOPSCurrentCapacityKey: capacity,
            kIOPSMaxCapacityKey: 100,
        ]
        if let charging { description[kIOPSIsChargingKey] = charging }
        if let timeToFull { description[kIOPSTimeToFullChargeKey] = timeToFull }
        if let timeToEmpty { description[kIOPSTimeToEmptyKey] = timeToEmpty }
        if let charged { description["Is Charged"] = charged }
        if let finishing { description["Is Finishing Charge"] = finishing }
        if let optimized { description["Optimized Battery Charging Engaged"] = optimized }
        return description
    }

    private func titles(_ description: [String: Any]) -> (full: String, compact: String) {
        let state = BatteryPowerService.snapshot(fromPowerSourceDescription: description).presentationState
        return (BatteryPresentationText.title(state), BatteryPresentationText.compactTitle(state))
    }

    private func assertTitles(_ description: [String: Any], _ expected: String,
                              _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let titles = titles(description)
        XCTAssertEqual(titles.full, expected, message, file: file, line: line)
        XCTAssertEqual(titles.compact, expected, message, file: file, line: line)
    }

    func testConnectedStatesThatAreNotEstimatesNeverSayCalculating() {
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        // pmset: "100%; finishing charge; 0:00 remaining" - the reviewed case
        // "电源适配器 · 正在计算".
        assertTitles(description(source: kIOPSACPowerValue, charging: true, timeToFull: 0, finishing: true),
                     "即将充满", "finishing charge at 100 %")
        // pmset: "100%; charged; 0:00 remaining".
        assertTitles(description(source: kIOPSACPowerValue, charging: false, timeToFull: 0, timeToEmpty: 0, charged: true),
                     "已充满", "charged")
        assertTitles(description(source: kIOPSACPowerValue, charging: true, timeToFull: -1, charged: true),
                     "已充满", "the charged flag wins over a stale estimate")
        assertTitles(description(source: kIOPSACPowerValue, charging: false, capacity: 80, timeToFull: 0, timeToEmpty: 0),
                     "已接通电源", "connected, not charging")
        assertTitles(description(source: kIOPSACPowerValue, charging: false, capacity: 80, timeToFull: -1, timeToEmpty: -1),
                     "已接通电源", "the time keys are not valid while not charging on AC")
        assertTitles(description(source: kIOPSACPowerValue, charging: false, capacity: 80, optimized: true),
                     "已暂停充电", "optimized charging paused")
        // Charging, and the system offers no time (0 or no key): no estimate
        // is being calculated.
        assertTitles(description(source: kIOPSACPowerValue, charging: true, capacity: 99, timeToFull: 0),
                     "正在充电", "charging with a zero estimate")
        assertTitles(description(source: kIOPSACPowerValue, charging: true, capacity: 60),
                     "正在充电", "charging without a time key")
        assertTitles(description(source: kIOPSBatteryPowerValue, charging: false, capacity: 60, timeToEmpty: 0),
                     "使用电池", "on battery with a zero estimate")
        assertTitles(description(source: kIOPSBatteryPowerValue, charging: false, capacity: 60),
                     "使用电池", "on battery without a time key")
        assertTitles(description(source: kIOPSBatteryPowerValue, charging: nil, capacity: 60),
                     "状态未知", "an unknown charging flag is not an estimate in progress")
    }

    func testCalculatingIsShownOnlyWhileTheSystemIsCalculating() {
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        assertTitles(description(source: kIOPSACPowerValue, charging: true, capacity: 60, timeToFull: -1),
                     "正在计算", "time to full is being calculated")
        assertTitles(description(source: kIOPSBatteryPowerValue, charging: false, capacity: 60, timeToEmpty: -1),
                     "正在计算", "time to empty is being calculated")
        // Only the key that is valid for the state counts.
        let charging = titles(description(source: kIOPSACPowerValue, charging: true, capacity: 60, timeToFull: 45, timeToEmpty: -1))
        XCTAssertEqual(charging.full, "预计 45 分钟后充满")
        XCTAssertEqual(charging.compact, "约 45 分后充满")
        let discharging = titles(description(source: kIOPSBatteryPowerValue, charging: false, capacity: 60, timeToFull: -1, timeToEmpty: 266))
        XCTAssertEqual(discharging.full, "剩余 4 小时 26 分钟")
        XCTAssertEqual(discharging.compact, "剩余约 4 小时 26 分")
    }

    func testPresentationStateSeparatesAnEstimateInProgressFromNoEstimate() {
        func state(_ description: [String: Any]) -> BatteryPresentationState {
            BatteryPowerService.snapshot(fromPowerSourceDescription: description).presentationState
        }
        XCTAssertEqual(state(description(source: kIOPSACPowerValue, charging: true, capacity: 60, timeToFull: -1)),
                       .charging(timeToFullMinutes: nil, isEstimating: true))
        XCTAssertEqual(state(description(source: kIOPSACPowerValue, charging: true, capacity: 60, timeToFull: 0)),
                       .charging(timeToFullMinutes: nil, isEstimating: false))
        XCTAssertEqual(state(description(source: kIOPSACPowerValue, charging: true, capacity: 60, timeToFull: 45)),
                       .charging(timeToFullMinutes: 45))
        XCTAssertEqual(state(description(source: kIOPSACPowerValue, charging: true, timeToFull: 0, finishing: true)),
                       .finishingCharge)
        XCTAssertEqual(state(description(source: kIOPSACPowerValue, charging: true, capacity: 97, timeToFull: 12, finishing: true)),
                       .charging(timeToFullMinutes: 12), "a real estimate is still shown while finishing")
        XCTAssertEqual(state(description(source: kIOPSACPowerValue, charging: false, capacity: 97, finishing: true)),
                       .connectedNotCharging, "finishing only describes a battery that is charging")
        XCTAssertEqual(state(description(source: kIOPSBatteryPowerValue, charging: false, capacity: 60, timeToEmpty: -1)),
                       .discharging(timeToEmptyMinutes: nil, isEstimating: true))
        XCTAssertEqual(state(description(source: kIOPSBatteryPowerValue, charging: false, capacity: 60, timeToEmpty: 0)),
                       .discharging(timeToEmptyMinutes: nil, isEstimating: false))
        XCTAssertEqual(state(description(source: kIOPSBatteryPowerValue, charging: nil, capacity: 60, timeToEmpty: -1)),
                       .unknown)

        // Snapshots built without the new facts keep their earlier meaning,
        // minus the unconditional "calculating".
        let plain = BatteryPowerSnapshot(chargePercent: 63, isCharging: true, powerSource: .acPower,
                                         timeToEmptyMinutes: nil, timeToFullChargeMinutes: nil)
        XCTAssertEqual(plain.presentationState, .charging(timeToFullMinutes: nil))
        XCTAssertFalse(plain.isCalculatingTimeToFullCharge)
        XCTAssertNil(plain.isFinishingCharge)
    }

    func testFinishingChargeKeepsTheChargingRingAndIcon() throws {
        let finishing = BatteryPowerService.snapshot(fromPowerSourceDescription:
            description(source: kIOPSACPowerValue, charging: true, timeToFull: 0, finishing: true))
        XCTAssertEqual(GeekBatteryRingState.resolve(snapshot: finishing), .charging)
        XCTAssertEqual(GeekBatteryRingState.resolve(snapshot: finishing).statusSymbol, "bolt.fill")
        let charging = BatteryPowerService.snapshot(fromPowerSourceDescription:
            description(source: kIOPSACPowerValue, charging: true, capacity: 60, timeToFull: 45))
        XCTAssertEqual(GeekBatteryRingState.resolve(snapshot: charging), .charging)
        XCTAssertEqual(GeekBatteryRingState.resolve(snapshot: charging).statusSymbol, "bolt.fill")
        let estimating = BatteryPowerService.snapshot(fromPowerSourceDescription:
            description(source: kIOPSBatteryPowerValue, charging: false, capacity: 60, timeToEmpty: -1))
        XCTAssertEqual(GeekBatteryRingState.resolve(snapshot: estimating), .discharging,
                       "an estimate in progress keeps its discharging context")
        let unknown = BatteryPowerService.snapshot(fromPowerSourceDescription:
            description(source: kIOPSBatteryPowerValue, charging: nil, capacity: 60))
        XCTAssertEqual(GeekBatteryRingState.resolve(snapshot: unknown), .unknown)

        let components = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift")
        // The retired batterySystemImage only fed an unused card parameter.
        // Both charging states still reach the live ring's informational bolt.
        let power = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift")
        let ringSymbol = try r2SourceDeclaration("private var geekBatteryRingSymbol:", in: power)
        let gaugeCard = try r2SourceDeclaration("private var geekPowerGaugeCard:", in: power)
        let panelComponents = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift")
        let ring = try r2SourceDeclaration("struct GeekCombinedRing:", in: panelComponents)
        XCTAssertTrue(ringSymbol.contains("GeekBatteryRingState.resolve(snapshot: batterySnapshot).statusSymbol"))
        XCTAssertTrue(gaugeCard.contains("statusSymbol: geekBatteryRingSymbol"))
        XCTAssertTrue(gaugeCard.contains("statusSymbolTint: panelMetricColors.batteryCharging"))
        XCTAssertTrue(ring.contains("if let statusSymbol {"))
        XCTAssertTrue(ring.contains("Image(systemName: statusSymbol)"))
        XCTAssertTrue(ring.contains(".foregroundStyle(statusSymbolTint ?? tint)"))
        XCTAssertTrue(components.contains("BatteryPresentationText.title(batteryPresentationState)"))
        XCTAssertTrue(components.contains("BatteryPresentationText.compactTitle(batteryPresentationState)"))
        XCTAssertEqual(components.components(separatedBy: "L10n.text(\"正在计算\", \"Calculating\")").count - 1, 1,
                       "one wording, reached only through isEstimating")
        let service = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Services/BatteryPowerService.swift")
        XCTAssertFalse(service.contains("case calculating"), "there is no state that always reads as calculating")
    }

    func testEnglishWording() {
        let scope = MiniWindowLogicLanguageScope(.english)
        defer { scope.restore() }
        assertTitles(description(source: kIOPSACPowerValue, charging: true, timeToFull: 0, finishing: true),
                     "Finishing Charge", "finishing")
        assertTitles(description(source: kIOPSACPowerValue, charging: true, capacity: 60), "Charging", "no estimate")
        assertTitles(description(source: kIOPSBatteryPowerValue, charging: false, capacity: 60), "On Battery", "no estimate")
        assertTitles(description(source: kIOPSACPowerValue, charging: true, capacity: 60, timeToFull: -1), "Calculating", "estimating")
    }
}
