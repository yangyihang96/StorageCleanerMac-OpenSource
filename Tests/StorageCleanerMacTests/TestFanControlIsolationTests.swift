import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class TestFanControlIsolationTests: XCTestCase {
    func testLiveCPUAndNetworkRefreshUsesAnIsolatedFanController() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let operations = TestOperationFactory(for: self)
        let controller = operations.fanControl(defaults: defaults)
        var providerCalls = 0
        let store = try ScanStore.makeForTests(for: self, fanControlProvider: {
            providerCalls += 1
            return controller
        })
        XCTAssertEqual(providerCalls, 0, "构造 store 仍不创建风扇控制器")
        store.refreshMenuBarLiveStatus()
        try await waitForSnapshot(store, newerThan: nil)
        XCTAssertEqual(providerCalls, 1, "真正的 CPU/网络刷新必须进入注入的风扇入口")
        let first = try XCTUnwrap(store.menuBarMonitorState.snapshot?.generatedAt)
        store.refreshMenuBarLiveStatus()
        try await waitForSnapshot(store, newerThan: first)
        XCTAssertEqual(providerCalls, 1, "每个 store 沿用同一惰性控制器")
        XCTAssertEqual(controller.selectedMode, .systemAutomatic)
        XCTAssertEqual(operations.unexpectedCalls, [])
    }

    func testProductionProviderRemainsLazyAndBothFanEntrypointsUseIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("fanControlProvider: @escaping @MainActor () -> FanControlCoordinator = { FanControlCoordinator.shared }"))
        XCTAssertTrue(source.contains("private lazy var fanControlCoordinator = fanControlProvider()"))
        XCTAssertTrue(source.contains("fanControlCoordinator.process(snapshot: result.snapshot)"))
        XCTAssertTrue(source.contains("fanControlCoordinator.manageStartupItem(plan)"))
        XCTAssertEqual(source.components(separatedBy: "FanControlCoordinator.shared").count - 1, 1)
        let factory = try String(contentsOf: root.appendingPathComponent("Tests/StorageCleanerMacTests/TestOperationFactory.swift"), encoding: .utf8)
        XCTAssertTrue(factory.contains("requestSender: fanRequestSender()"))
        XCTAssertTrue(factory.contains("serviceStatusProvider: { .notRegistered }"))
        let coordinator = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Services/FanControlCoordinator.swift"), encoding: .utf8)
        XCTAssertTrue(coordinator.contains("if requestSender == nil {\n            installLifecycleObservers()"))
    }

    func testOtherProductionFanEntrypointsKeepTheirDefaultsAndForwardInjection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let expectations: [(String, [String])] = [
            ("Services/BatteryHealthService.swift", [
                "powerModeWriter: any BatteryPowerModeCommandRunning = PrivilegedBatteryPowerModeCommandRunner()",
                "let coordinator = await fanControlProvider()",
                "let verifiedModes = try await coordinator.applyPowerMode(command)"
            ]),
            ("Support/MenuBarStatusController.swift", [
                "private lazy var fanControl = fanControlProvider()", "fanControl.$selectedMode",
                "let customFanControlActive = fanControl.selectedMode", "paletteFanControl = fanControl"
            ]),
            ("Support/GeekDashboardConfigurationStore.swift", ["let fan = fanControlProvider()"]),
            ("Views/SettingsView.swift", [
                "fanControl: @autoclosure @escaping @MainActor () -> FanControlCoordinator = FanControlCoordinator.shared",
                "_fanControl = StateObject(wrappedValue: fanControl())"
            ])
        ]
        for (path, needles) in expectations {
            let source = try SettingsSourceContract.source(at: root.appendingPathComponent("Sources/StorageCleanerMac/" + path))
            XCTAssertEqual(source.components(separatedBy: "FanControlCoordinator.shared").count - 1, 1, path)
            for needle in needles { XCTAssertTrue(source.contains(needle), "\(path): \(needle)") }
        }
        let palette = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift"), encoding: .utf8)
        XCTAssertTrue(palette.contains("fanControl: FanControlCoordinator = .shared"))
        let advanced = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"), encoding: .utf8)
        XCTAssertTrue(advanced.contains("self.fanControl = fanControl ?? FanControlCoordinator.shared"))
    }

    private struct Timeout: Error {}
    private func waitForSnapshot(_ store: ScanStore, newerThan date: Date?) async throws {
        let deadline = Date().addingTimeInterval(15)
        while store.menuBarMonitorState.snapshot == nil || store.menuBarMonitorState.snapshot?.generatedAt == date {
            guard Date() < deadline else { XCTFail("等待真实 CPU/网络只读刷新超时"); throw Timeout() }
            await Task.yield()
        }
    }
}
