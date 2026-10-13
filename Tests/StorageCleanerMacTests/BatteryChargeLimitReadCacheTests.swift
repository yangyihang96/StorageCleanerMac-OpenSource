import Foundation
import XCTest
@testable import StorageCleanerMac

final class BatteryChargeLimitReadCacheTests: XCTestCase {
    @MainActor
    func testVisibleSamplingUsesInjectedClockAndThirtySecondCache() {
        let clock = TestClock(10)
        var reads = 0
        let cache = BatteryChargeLimitReadCache(clock: { clock.now }, read: { reads += 1; return nil })
        _ = cache.refresh(reason: .panelOpened, hasInternalBattery: true, isPanelVisible: true, allowsLiveAccess: true)
        clock.now += 29.999
        _ = cache.refresh(reason: .visibleSampling, hasInternalBattery: true, isPanelVisible: true, allowsLiveAccess: true)
        XCTAssertEqual(reads, 1, "读失败也必须节流")
        clock.now = 40
        _ = cache.refresh(reason: .visibleSampling, hasInternalBattery: true, isPanelVisible: true, allowsLiveAccess: true)
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testHiddenPanelNeverReadsEvenAfterThirtySeconds() {
        let clock = TestClock(0)
        var reads = 0
        let state = BatteryChargeLimitState(target: .full, availableTargets: [.protected, .full],
                                           effectiveLimit: 80, source: .optimized)
        let cache = BatteryChargeLimitReadCache(clock: { clock.now }, read: { reads += 1; return state })
        for _ in 0..<50 {
            _ = cache.refresh(reason: .visibleSampling, hasInternalBattery: true, isPanelVisible: false, allowsLiveAccess: true)
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(cache.refresh(reason: .panelOpened, hasInternalBattery: true, isPanelVisible: true, allowsLiveAccess: true), state)
        clock.now = 100
        XCTAssertEqual(cache.refresh(reason: .visibleSampling, hasInternalBattery: true, isPanelVisible: false, allowsLiveAccess: true), state)
        XCTAssertEqual(reads, 1, "后台保留缓存，但不能重新读取")
    }

    @MainActor
    func testNoBatteryAndDataOnlyModesNeverInvokeReaderForAnyReason() {
        for reason: BatteryChargeLimitReadReason in [.panelOpened, .visibleSampling, .userOperation] {
            let cache = BatteryChargeLimitReadCache(read: { XCTFail("不得创建或调用客户端"); return nil })
            XCTAssertNil(cache.refresh(reason: reason, hasInternalBattery: false, isPanelVisible: true, allowsLiveAccess: true))
            XCTAssertNil(cache.refresh(reason: reason, hasInternalBattery: true, isPanelVisible: true, allowsLiveAccess: false))
        }
        XCTAssertTrue(BatteryChargeLimitAccess.allowsLiveAccess(isDemo: false, isFixture: false))
        for (demo, fixture) in [(true, false), (false, true), (true, true)] {
            XCTAssertFalse(BatteryChargeLimitAccess.allowsLiveAccess(isDemo: demo, isFixture: fixture))
        }
    }

    @MainActor
    func testUserOperationAndReopeningImmediatelyReadOnceThenRestartThrottle() {
        let clock = TestClock(0)
        var reads = 0
        let cache = BatteryChargeLimitReadCache(clock: { clock.now }, read: { reads += 1; return nil })
        _ = cache.refresh(reason: .panelOpened, hasInternalBattery: true, isPanelVisible: true, allowsLiveAccess: true)
        clock.now = 1
        _ = cache.refresh(reason: .userOperation, hasInternalBattery: true, isPanelVisible: false, allowsLiveAccess: true)
        XCTAssertEqual(reads, 2)
        clock.now = 30
        _ = cache.refresh(reason: .visibleSampling, hasInternalBattery: true, isPanelVisible: true, allowsLiveAccess: true)
        XCTAssertEqual(reads, 2)
        _ = cache.refresh(reason: .panelOpened, hasInternalBattery: true, isPanelVisible: true, allowsLiveAccess: true)
        XCTAssertEqual(reads, 3)
    }

    func testOnlyPowerPageDeclaresChargeLimitDemand() {
        for density: PanelDensity in [.simple, .complex, .geek] {
            for section: PanelSection in [.overview, .processor, .memory, .disk, .network, .sensors, .power] {
                XCTAssertEqual(density.auxiliaryDemand(for: section).needsChargeLimit,
                               density != .simple && section == .power,
                               "\(density) \(section) 只有显示上限的电源页需要读取")
            }
        }
        let nonPowerDemand = MenuBarAuxiliaryMonitorDemand(
            needsProcessorTelemetry: true, needsDiskIOSampling: true,
            needsNetworkInterface: true, needsPublicNetworkAddress: true, needsNetworkProcesses: true,
            needsStorageVolumes: true
        )
        XCTAssertFalse(nonPowerDemand.needsChargeLimit, "其他监测需求不能隐式启用充电上限")
    }

    @MainActor
    func testVisibleReadsFollowChargeLimitConsumersAndStopWhenLastOneLeaves() {
        let clock = TestClock(0)
        var reads = 0
        let value = BatteryChargeLimitState(target: .full, availableTargets: [],
                                            effectiveLimit: 80, source: .optimized)
        let state = MenuBarAuxiliaryMonitorState(
            batteryAvailabilityProvider: { .present }, diskCounterProvider: { nil },
            storageVolumeProvider: { .empty }, batterySnapshotProvider: { (nil, nil) },
            powerHistoryURL: nil, chargeLimitClock: { clock.now },
            chargeLimitReader: { reads += 1; return value }
        )
        let unrelated = UUID(), page = UUID(), palette = UUID()
        defer {
            state.setPaused(true)
            for id in [unrelated, page, palette] { state.unregisterConsumer(id) }
        }
        let unrelatedDemand = MenuBarAuxiliaryMonitorDemand(
            needsProcessorTelemetry: false, needsDiskIOSampling: false,
            needsNetworkInterface: false, needsPublicNetworkAddress: false, needsNetworkProcesses: false
        )
        let powerDemand = PanelDensity.geek.auxiliaryDemand(for: .power)
        state.registerConsumer(unrelated, demand: unrelatedDemand, paused: false)
        for time: TimeInterval in [0, 30, 60] {
            clock.now = time
            state.refreshBatteryChargeLimitState()
        }
        XCTAssertEqual(reads, 0, "只开简单面板或性能基准页时不能读上限")

        state.updateConsumer(page, demand: powerDemand)
        state.refreshBatteryChargeLimitState()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(state.batteryChargeLimitState, value)
        state.updateConsumer(palette, demand: powerDemand)
        state.unregisterConsumer(page)
        clock.now = 90
        state.refreshBatteryChargeLimitState()
        XCTAssertEqual(reads, 2, "还有电源调板需求时继续按 30 秒节流")
        state.updateConsumer(palette, demand: unrelatedDemand)
        clock.now = 120
        state.refreshBatteryChargeLimitState()
        XCTAssertEqual(reads, 2, "需求从电源切到其他页后立即停止读取")
        XCTAssertEqual(state.batteryChargeLimitState, value, "隐藏时仍保留既有只读缓存")

        state.updateConsumer(palette, demand: powerDemand)
        state.setPaused(true)
        clock.now = 150
        state.refreshBatteryChargeLimitState()
        XCTAssertEqual(reads, 2, "暂停仍优先于需求标志")
        state.unregisterConsumer(palette)
        state.setPaused(false)
        state.refreshBatteryChargeLimitState()
        XCTAssertEqual(reads, 2, "移除最后一个显示上限的需求方后，其他消费者仍不触发读取")
        state.refreshBatteryChargeLimitState(reason: .userOperation)
        XCTAssertEqual(reads, 3, "显式操作后的只读回读继续绕过可见节流")
    }

    func testPowerPaletteRegistersItsOwnDemandAndOtherSurfacesKeepDefault() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/" + path), encoding: .utf8)
        }
        let palette = try source("MenuBarAdvanced/ControlPaletteViews.swift")
        let start = try XCTUnwrap(palette.range(of: "private var powerPalette:"))
        let end = try XCTUnwrap(palette.range(of: "private var allowsLiveChargeLimitControls:",
                                            range: start.lowerBound..<palette.endIndex))
        let power = String(palette[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(power.contains("auxiliaryState.updateConsumer(chargeLimitConsumerID, demand:"))
        XCTAssertTrue(power.contains("needsChargeLimit: true"))
        XCTAssertTrue(power.contains(".onDisappear"))
        XCTAssertTrue(power.contains("auxiliaryState.unregisterConsumer(chargeLimitConsumerID)"))
        let panel = try source("MenuBarAdvancedStatusView.swift")
        let policy = try r2SourceDeclaration("func auxiliaryDemand(", in: panel)
        XCTAssertTrue(policy.contains("needsChargeLimit: usesGeekLayout && section == .power"))
        XCTAssertFalse(policy.contains("needsChargeLimit: true"))
        for path in ["ComputerHealth/PerformanceBenchmarkWorkspaceView.swift"] {
            let other = try source(path)
            XCTAssertTrue(other.contains("MenuBarAuxiliaryMonitorDemand("))
            XCTAssertFalse(other.contains("needsChargeLimit: true"), path)
            XCTAssertFalse(other.contains("refreshBatteryChargeLimitState("), path)
        }
    }

    func testProductionEntryChecksBatteryBeforeCreatingClientAndSamplingUsesCache() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let service = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Services/BatteryFullChargeService.swift"), encoding: .utf8)
        let start = try XCTUnwrap(service.range(of: "private static var smartChargeClient:"))
        let end = try XCTUnwrap(service.range(of: "static func currentChargeLimitState()", range: start.lowerBound..<service.endIndex))
        let factory = String(service[start.lowerBound..<end.lowerBound])
        let batteryGuard = try XCTUnwrap(factory.range(of: "internalBatteryAvailability() == .present"))
        let make = try XCTUnwrap(factory.range(of: "PowerUISmartChargeClient.make()"))
        XCTAssertLessThan(batteryGuard.lowerBound, make.lowerBound)
        XCTAssertTrue(factory.contains("BatteryChargeLimitAccess.allowsLiveAccess"))
        XCTAssertTrue(service.contains("BatteryChargeLimitObjCCalls.decodeManualEnabled(unsignedValue(for: \"isMCLCurrentlyEnabled:\"))"),
                      "R11：生产读取必须使用只认 0/1 的解码函数")
        let monitor = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Support/MenuBarAuxiliaryMonitorState.swift"), encoding: .utf8)
        let sampleStart = try XCTUnwrap(monitor.range(of: "private func recordBatterySample("))
        let sample = String(monitor[sampleStart.lowerBound...])
        XCTAssertTrue(sample.contains("data.batteryChargeLimitState = chargeLimitReadCache.refresh("))
        XCTAssertTrue(sample.contains("isPanelVisible: !isPaused && combinedDemand.needsChargeLimit"))
        XCTAssertEqual(monitor.components(separatedBy: "isPanelVisible: !isPaused && combinedDemand.needsChargeLimit").count - 1, 2,
                       "显式刷新与电池采样两处都只看充电上限需求")
        XCTAssertFalse(sample.contains("BatteryFullChargeService.reconcileSystemTarget()"))
    }
}

/// 可变时钟放进主线程隔离的引用类型，避免 Sendable 闭包捕获后再修改局部变量。
@MainActor
private final class TestClock {
    var now: TimeInterval
    init(_ now: TimeInterval) { self.now = now }
}
