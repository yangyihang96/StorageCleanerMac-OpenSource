#if DEBUG
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D154 batch 2: the D160–D165 tool pages are reachable from the module
/// they belong to (CleanMyMac's place for them), from My Tools, and from
/// the process notes; no page of this wiring reads the system in a test.
@MainActor
final class CareStudioToolboxWiringTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testToolPagesBelongToTheModulesCleanMyMacPutsThemIn() {
        XCTAssertEqual(CareStudioFamily(route: .extensions), .applications)
        XCTAssertEqual(CareStudioFamily(route: .maintenance), .performance)
        XCTAssertEqual(CareStudioFamily(route: .chatFiles), .clutter)
        XCTAssertEqual(CareStudioModule(filter: .extensions)?.family, .applications)
        XCTAssertEqual(CareStudioModule(filter: .maintenance)?.family, .performance)
        XCTAssertEqual(CareStudioModule(filter: .chatFiles)?.family, .clutter)
        for route in [ReviewFilter.extensions, .maintenance, .chatFiles] {
            XCTAssertEqual(route.sidebarDestination, route)
            XCTAssertFalse(route.title.isEmpty)
            XCTAssertTrue(MyToolsCatalog.tools.contains { $0.destination == .route(route) }, route.rawValue)
        }
    }

    func testEachToolPageOpensFromItsModule() throws {
        let router = try source("Sources/StorageCleanerMac/Views/ContentView.swift")
        XCTAssertTrue(router.contains("ExtensionManagerPage(store: ToolboxStores.of(store).extensions, module: .applications,"))
        XCTAssertTrue(router.contains("SystemMaintenancePage(store: ToolboxStores.of(store).maintenance, module: .startup,"))
        XCTAssertTrue(router.contains("openFreeUpMemory: { store.showFilter(.memory) })"))
        XCTAssertTrue(router.contains("ChatFilesPage(store: ToolboxStores.of(store).chatFiles, module: .clutter,"))
        // Applications results: the Extensions tile, read with the apps (read-only listing).
        let applications = try source("Sources/StorageCleanerMac/Views/CareStudio/CareStudioApplications.swift")
        XCTAssertTrue(applications.contains("onReview: { store.showFilter(.extensions) }"))
        XCTAssertTrue(applications.contains("if !isFixture, extensions.inventory == nil, !extensions.isBusy { extensions.scan() }"))
        // Performance results: Maintenance first.
        let startup = try source("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        XCTAssertTrue(startup.contains("leadingTiles: [maintenanceTile]"))
        // Report §4 item 13: `CareStudioTileModel.maintenance` builds the tile
        // (was `onReview: { store.showFilter(.maintenance) }, art: .tileMaintenance)`
        // in one line); Review still opens the maintenance page, and the tile
        // keeps its art (`SystemMaintenanceTests` reads it from the model).
        XCTAssertTrue(startup.contains(".maintenance(maintenance, onReview: { store.showFilter(.maintenance) })"))
        XCTAssertTrue(startup.contains("art: .tileMaintenance)"))
        XCTAssertTrue(startup.contains(".onChange(of: store.isLoadingStartupItems) { _, loading in\n            if loading, !isFixture, !maintenance.isRefreshing { maintenance.refresh() }"))
        // My Clutter: the landing offers Chat Files.
        XCTAssertEqual(CareStudioModule.clutter.relatedTools, [.chatFiles])
        for module in CareStudioModule.allCases where module != .clutter {
            XCTAssertTrue(module.relatedTools.isEmpty, module.rawValue)
        }
        // Duplicates: “Merge into Clones” on the result toolbar, fed by the scan's proven groups.
        let duplicates = try source("Sources/StorageCleanerMac/Views/FilesLightfield/DuplicateFilesLightfieldView.swift")
        XCTAssertTrue(duplicates.contains("DuplicateCloneMergeOffer(action: cloneMerge, groups: workspace.exactGroups)"))
        XCTAssertTrue(duplicates.contains(".onChange(of: groups) { _, newGroups in action.update(groups: newGroups) }"))
    }

    func testProcessNoteLinksOpenTheirPages() {
        XCTAssertEqual(LightfieldMemoryAppRow.route(for: .extensions), .extensions)
        XCTAssertEqual(LightfieldMemoryAppRow.route(for: .maintenance), .maintenance)
        // iOS backups are listed on Space Map (file analysis).
        XCTAssertEqual(LightfieldMemoryAppRow.route(for: .mobileBackups), .largeFiles)
    }

    func testToolStoresAreSharedPerScanStore() throws {
        let store = try ScanStore.makeForTests(for: self)
        let stores = ToolboxStores.of(store)
        XCTAssertTrue(ToolboxStores.of(store) === stores)
        XCTAssertTrue(ToolboxStores.of(store).extensions === stores.extensions)
        let other = try ScanStore.makeForTests(for: self)
        XCTAssertFalse(ToolboxStores.of(other) === stores)
        // Nothing is read until a page or a result tile asks.
        XCTAssertNil(stores.extensions.inventory)
        XCTAssertFalse(stores.maintenance.hasStatuses)
        XCTAssertNil(stores.chatFiles.inventory)
        XCTAssertTrue(stores.cloneMerge.groups.isEmpty)
    }
}
#endif
