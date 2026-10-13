import Foundation
import XCTest
@testable import StorageCleanerMac

final class MenuBarCachedHealthTests: XCTestCase {
    func testAdvancedMenuReceivesRootHealthStoreAndOnlyReadsCachedSummary() throws {
        let root = projectRoot
        let appSource = try source("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift", root: root)
        let controllerSource = try source(
            "Sources/StorageCleanerMac/Support/MenuBarStatusController.swift",
            root: root
        )
        let panelRootSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift",
            root: root
        )
        let advancedSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift",
            root: root
        )
        let diskSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift",
            root: root
        )
        let networkSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift",
            root: root
        )
        let powerSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift",
            root: root
        )
        let combinedSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift",
            root: root
        )

        XCTAssertTrue(appSource.contains("menuBarStatusController.install("))
        XCTAssertTrue(appSource.contains("computerHealthStore: computerHealthStore"))
        XCTAssertTrue(controllerSource.contains("private weak var computerHealthStore: ComputerHealthStore?"))
        XCTAssertTrue(controllerSource.contains("PanelScene("))
        XCTAssertTrue(panelRootSource.contains("let store: ScanStore"))
        XCTAssertTrue(panelRootSource.contains("let computerHealthStore: ComputerHealthStore"))
        XCTAssertFalse(panelRootSource.contains("@ObservedObject var store"))
        XCTAssertFalse(panelRootSource.contains("@ObservedObject var computerHealthStore"))
        XCTAssertTrue(panelRootSource.contains("self.store = store"))
        XCTAssertTrue(panelRootSource.contains("self.computerHealthStore = computerHealthStore"))
        XCTAssertTrue(panelRootSource.contains("MenuBarAdvancedStatusView("))
        XCTAssertTrue(panelRootSource.contains("store: store"))
        XCTAssertTrue(panelRootSource.contains("computerHealthStore: computerHealthStore"))
        XCTAssertTrue(advancedSource.contains("let store: ScanStore"))
        XCTAssertTrue(advancedSource.contains("let computerHealthStore: ComputerHealthStore"))
        let liveCards = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarLiveCard.swift", root: root)
        XCTAssertTrue(liveCards.contains("computerHealthStore.snapshot?.generatedAt"))
        XCTAssertFalse(advancedSource.contains("@ObservedObject var computerHealthStore"))
        XCTAssertTrue(advancedSource.contains("computerHealthStore.menuBarSummary"))

        XCTAssertTrue(diskSource.contains("healthSummary?.diskSMARTStatus"))
        XCTAssertTrue(diskSource.contains("healthSummary?.diskRemainingLifePercent"))
        XCTAssertTrue(diskSource.contains("computerHealthStore.snapshot?.disk.smartStatus"))
        XCTAssertTrue(diskSource.contains("computerHealthStore.snapshot?.disk.remainingLifePercent"))
        XCTAssertTrue(networkSource.contains("connection.activeInterface"))
        XCTAssertTrue(networkSource.contains("networkDownText"))
        XCTAssertTrue(networkSource.contains("networkUpText"))
        XCTAssertTrue(powerSource.contains("healthSummary?.batteryCapacityPercent"))
        XCTAssertTrue(powerSource.contains("healthSummary?.batteryCycleCount"))
        XCTAssertTrue(powerSource.contains("healthSummary?.batteryCondition"))
        XCTAssertTrue(powerSource.contains("healthSummary?.batteryPowerMode"))

        let menuSources = [
            controllerSource,
            panelRootSource,
            advancedSource,
            diskSource,
            networkSource,
            powerSource,
            combinedSource
        ]
            .joined(separator: "\n")
        // The live power page already performs a gated read on opening. No
        // health read belongs in a renderer or a fingerprint.
        XCTAssertFalse(liveCards.contains("computerHealthStore.refresh("))
        let powerPage = try r2SourceDeclaration("var geekPowerPage:", in: powerSource)
        XCTAssertTrue(powerPage.contains("guard !MiniWindowDemoData.isEnabled else { return }"))
        XCTAssertTrue(powerPage.contains("guard BatteryChargeLimitAccess.allowsLiveAccess else { return }"))
        XCTAssertTrue(powerPage.contains(".task {"))
        XCTAssertFalse(menuSources.contains("NetworkSpeedTestStore("))
        XCTAssertFalse(menuSources.contains("startScanRespectingAccessGuide()"))
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
