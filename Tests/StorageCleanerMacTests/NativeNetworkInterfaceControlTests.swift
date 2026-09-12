import XCTest
@testable import StorageCleanerMac

final class NativeNetworkInterfaceControlTests: XCTestCase {
    func testPowerControlUsesCoreWLANWithoutShellFallback() throws {
        let source = try sourceText(
            at: "Sources/StorageCleanerMac/Services/NativeNetworkInterfaceService.swift"
        )

        XCTAssertTrue(source.contains("$0.powerOn()"))
        XCTAssertTrue(source.contains("setDefaultWiFiPower(_ isOn: Bool)"))
        XCTAssertTrue(source.contains("try interface.setPower(isOn)"))
        XCTAssertTrue(source.contains("interface.powerOn()"))
        XCTAssertFalse(source.contains("setWiFiPower(_ isOn: Bool, interfaceName: String)"))
        XCTAssertFalse(source.contains("networksetup"))
        XCTAssertFalse(source.contains("Process("))
    }

    @MainActor
    func testPowerControlIsLatestWinsAndNeverRunsRequestsConcurrently() async {
        let gate = WiFiPowerRequestGate()
        let coordinator = WiFiPowerControlCoordinator { enabled in
            await gate.send(enabled)
        }
        coordinator.synchronize(confirmedPower: true)

        coordinator.request(false)
        await gate.waitForCallCount(1)
        coordinator.request(true)
        await gate.resolveFirst(with: .success(false))
        await gate.waitForCallCount(2)

        XCTAssertTrue(coordinator.isApplying)
        XCTAssertEqual(coordinator.requestedPower, true)
        let inFlightMetrics = await gate.snapshot()
        XCTAssertEqual(inFlightMetrics.maximumConcurrentRequests, 1)

        await gate.resolveFirst(with: .success(true))
        await waitUntil { !coordinator.isApplying }

        let completedMetrics = await gate.snapshot()
        XCTAssertEqual(completedMetrics.calls, [false, true])
        XCTAssertEqual(coordinator.confirmedPower, true)
        XCTAssertNil(coordinator.requestedPower)
        XCTAssertNil(coordinator.lastError)
    }

    @MainActor
    func testFailedPowerChangeRollsBackToConfirmedReadbackState() async {
        let coordinator = WiFiPowerControlCoordinator { _ in
            .failure(.operationRejected)
        }
        coordinator.synchronize(confirmedPower: true)

        coordinator.request(false)
        await waitUntil { !coordinator.isApplying }

        XCTAssertEqual(coordinator.confirmedPower, true)
        XCTAssertNil(coordinator.requestedPower)
        XCTAssertEqual(coordinator.lastError, .operationRejected)
    }

    func testWiFiPHYAndBandLabelsOnlyMapKnownCoreWLANValues() {
        XCTAssertEqual(NativeNetworkInterfaceService.wiFiPHYMode(rawValue: 6), "802.11ax")
        XCTAssertEqual(NativeNetworkInterfaceService.wiFiPHYMode(rawValue: 7), "802.11be")
        XCTAssertNil(NativeNetworkInterfaceService.wiFiPHYMode(rawValue: 0))
        XCTAssertEqual(NativeNetworkInterfaceService.channelBandGHz(rawValue: 1), 2)
        XCTAssertEqual(NativeNetworkInterfaceService.channelBandGHz(rawValue: 2), 5)
        XCTAssertEqual(NativeNetworkInterfaceService.channelBandGHz(rawValue: 3), 6)
        XCTAssertNil(NativeNetworkInterfaceService.channelBandGHz(rawValue: 0))
    }

    func testGeekControlConfirmsPowerOffRefreshesAndSupportsVoiceOver() throws {
        let source = try sourceText(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift"
        )

        XCTAssertTrue(source.contains("Wi-Fi 当前已开启"))
        XCTAssertTrue(source.contains("Wi-Fi 当前已关闭"))
        XCTAssertTrue(source.contains(".confirmationDialog("))
        XCTAssertTrue(source.contains("WiFiPowerControlCoordinator"))
        XCTAssertTrue(source.contains("coordinator.request("))
        XCTAssertTrue(source.contains("refresh()"))
        XCTAssertTrue(source.contains("Wi-Fi 控制不可用"))
        XCTAssertTrue(source.contains(".accessibilityHint("))
        XCTAssertFalse(source.contains("Timer."))
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 where !predicate() {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(predicate())
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(at relativePath: String) throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private actor WiFiPowerRequestGate {
    private(set) var calls: [Bool] = []
    private(set) var maximumConcurrentRequests = 0
    private var activeRequests = 0
    private var pending: [CheckedContinuation<Result<Bool, NetworkControlError>, Never>] = []

    func send(_ enabled: Bool) async -> Result<Bool, NetworkControlError> {
        calls.append(enabled)
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
        let result = await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
        activeRequests -= 1
        return result
    }

    func waitForCallCount(_ count: Int) async {
        while calls.count < count {
            await Task.yield()
        }
    }

    func resolveFirst(with result: Result<Bool, NetworkControlError>) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: result)
    }

    func snapshot() -> (calls: [Bool], maximumConcurrentRequests: Int) {
        (calls, maximumConcurrentRequests)
    }
}
