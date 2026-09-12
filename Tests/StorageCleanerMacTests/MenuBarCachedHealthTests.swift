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
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarDiskPanel.swift",
            root: root
        )
        let networkSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarNetworkPanel.swift",
            root: root
        )
        let powerSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarPowerPanel.swift",
            root: root
        )
        let combinedSource = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarCombinedPanel.swift",
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
        XCTAssertTrue(advancedSource.contains(
            "MenuBarObservedObjectBoundary(model: computerHealthStore)"
        ))
        XCTAssertTrue(advancedSource.contains("computerHealthStore.menuBarSummary"))

        XCTAssertTrue(diskSource.contains("healthSummary?.diskSMARTStatus"))
        XCTAssertTrue(diskSource.contains("healthSummary?.diskStatusText"))
        XCTAssertTrue(diskSource.contains("healthSummary?.capacitySevenDayDeltaBytes"))
        XCTAssertTrue(diskSource.contains("healthSummary?.backupStatusText"))
        XCTAssertTrue(networkSource.contains("healthSummary?.lastDownloadMbps"))
        XCTAssertTrue(networkSource.contains("healthSummary?.lastUploadMbps"))
        XCTAssertTrue(networkSource.contains("healthSummary?.lastSpeedTestAt"))
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
        XCTAssertFalse(menuSources.contains("computerHealthStore.refresh("))
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
