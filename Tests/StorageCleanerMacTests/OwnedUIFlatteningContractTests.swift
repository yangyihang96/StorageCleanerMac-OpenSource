import Foundation
import XCTest

final class OwnedUIFlatteningContractTests: XCTestCase {
    func testManagementPagesKeepSelectionSeparateFromExecution() throws {
        let utilities = try sourceText("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let uninstall = try sourceSegment(utilities, from: "struct AppUninstallerView", to: "struct RelatedAppFilesReviewSheet")
        // CleanMyMac Applications manager: checkboxes select, the primary
        // action alone starts a removal, Finder hand-offs only select.
        XCTAssertTrue(uninstall.contains("ApplicationsManagerView(store: store)"))
        XCTAssertFalse(uninstall.contains("!store.hasScannedInstalledApps || store.isLoadingInstalledApps"))
        let applicationsManager = try sourceText("Sources/StorageCleanerMac/Views/ApplicationsManager/ApplicationsManagerView.swift")
        XCTAssertEqual(applicationsManager.components(separatedBy: "model.requestRemoval()").count - 1, 1)
        let finder = try sourceSegment(applicationsManager, from: "private func takeFinderRequest()", to: "private var terminatorBinding")
        XCTAssertTrue(finder.contains("store.cancelUninstall()"))
        XCTAssertTrue(finder.contains("model.toggle(entry)"))
        XCTAssertFalse(finder.contains("requestRemoval"))
        XCTAssertFalse(finder.contains("confirmUninstall"))
        XCTAssertTrue(applicationsManager.contains("if let app = store.pendingUninstallApp { UninstallPreviewSheet(store: store, app: app) }"))

        let updates = try sourceText("Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift")
        let manager = try sourceSegment(updates, from: "private struct AppUpdateManagerPage", to: "private struct AppUpdateCatalogRow")
        XCTAssertTrue(manager.contains("selectedUpdateApplicationIDs.subtracting(visibleEligibleApplicationIDs).count"))
        XCTAssertTrue(manager.contains("selectedUpdateApplicationIDs.formUnion(visibleEligibleApplicationIDs)"))
        XCTAssertTrue(manager.contains("onUpdateAutomatic(selectedUpdateApplicationIDs)"))
        let initialSelection = try sourceSegment(manager, from: ".onAppear {", to: ".onChange(of: snapshot.sessionID)")
        XCTAssertFalse(initialSelection.contains("selectedUpdateApplicationIDs ="))
    }

    func testCompactPanelUsesSemanticFlatControlsAndExplicitDirections() throws {
        // D64 removes the unused compact layout. Inspect the live navigation,
        // directional network readings, cleanup summary and result controls.
        let chrome = try D64MenuBarSource.source("MenuBarPanelChrome.swift")
        XCTAssertEqual(chrome.components(separatedBy: "AppIconButton(").count - 1, 1)
        XCTAssertEqual(chrome.components(separatedBy: "kind: .toolbar").count - 1, 1)
        XCTAssertEqual(chrome.components(separatedBy: "Menu {").count - 1, 2)
        XCTAssertTrue(chrome.contains("struct PanelRefreshControl: View"))
        XCTAssertTrue(chrome.contains("AppSymbols.Action.more"))
        XCTAssertTrue(chrome.contains("Text(L10n.text(\"打开主窗口\", \"Open Main Window\"))"))
        XCTAssertTrue(chrome.contains(".accessibilityLabel(L10n.text(\"更多小窗操作\", \"More Panel Actions\"))"))
        XCTAssertFalse(chrome.contains("退出存储清理助手"))
        XCTAssertFalse(chrome.contains("Color.gray"))
        let network = try D64MenuBarSource.source("MenuBarAdvanced/GeekNetworkView.swift")
        // D146: iStat's peak row names each direction (were the arrows
        // `direction: "↓"` and `direction: "↑"`).
        XCTAssertTrue(network.contains("GeekIStatPeakValue(title: L10n.text(\"上传\", \"Upload\")"))
        XCTAssertTrue(network.contains("GeekIStatPeakValue(title: L10n.text(\"下载\", \"Download\")"))
        XCTAssertFalse(network.contains("direction: \"↓\""))
        XCTAssertFalse(network.contains("direction: \"↑\""))
        XCTAssertTrue(network.contains("Download peak"))
        XCTAssertTrue(network.contains("Upload peak"))
        XCTAssertTrue(network.contains(".accessibilityLabel("))
        let settings = try D64MenuBarSource.source("MenuBarPanelSettingsView.swift")
        XCTAssertFalse(settings.contains("退出存储清理助手"))
        XCTAssertFalse(settings.contains("struct PanelSettingsView: View"))
        XCTAssertFalse(settings.contains("Form {"))
        XCTAssertFalse(settings.contains("xmark"))
        let cleanup = try D64MenuBarSource.source("MenuBarAdvanced/GeekCleanupView.swift")
        let row = try r2SourceDeclaration("struct AdvancedSmartCleanupItemRow:", in: cleanup)
        XCTAssertFalse(row.contains("Button"))
        XCTAssertFalse(row.contains("chevron"))
        XCTAssertTrue(row.contains(".accessibilityElement(children: .combine)"))
        let memory = try D64MenuBarSource.source("MenuBarAdvanced/GeekMemoryView.swift")
        let result = try r2SourceDeclaration("private struct GeekMemoryQuitResultCard:", in: memory)
        XCTAssertFalse(result.contains("Capsule("))
        // D126: iStat's text section and button items (was the arrow between
        // two rings, `Button(L10n.text("完成", "Done")` and
        // `Text(L10n.text("查看报告", "View Report"))` in bordered buttons).
        XCTAssertFalse(result.contains("Image(systemName: \"arrow.right\")"))
        XCTAssertTrue(result.contains("GeekIStatButtonItem(title: L10n.text(\"完成\", \"Done\"), kind: .standard"))
        XCTAssertTrue(result.contains("GeekIStatButtonItem(title: L10n.text(\"查看报告\", \"View Report\"), kind: .standard"))
        let panel = try D64MenuBarSource.source("MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(panel.contains("PanelShell("))
        XCTAssertFalse(panel.contains(".appGlassSegmentedControl()"))
        XCTAssertFalse(panel.contains("matchedGeometryEffect"))
    }

    func testSystemUtilitiesUseNativeLinearProgressAndFlatRows() throws {
        let source = try sourceText("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let startupDashboard = try sourceText(
            "Sources/StorageCleanerMac/Features/StartupItems/Views/StartupItemsDashboardView.swift"
        )

        let energyHeader = try sourceSegment(
            source,
            from: "private struct EnergyImpactTableHeader",
            to: "private struct EnergyImpactAppRow"
        )
        XCTAssertFalse(energyHeader.contains("RoundedRectangle("))
        XCTAssertFalse(energyHeader.contains(".background("))

        let energyRow = try sourceSegment(
            source,
            from: "private struct EnergyImpactAppRow",
            to: "private struct EnergyImpactValueColumn"
        )
        XCTAssertTrue(energyRow.contains("AppIconButton("))
        XCTAssertTrue(energyRow.contains("title: L10n.text(\"切换到应用\", \"Switch to app\")"))

        let energyProgress = try sourceSegment(
            source,
            from: "private struct EnergyImpactUsageBar",
            to: "struct AppUninstallerView"
        )
        assertNativeLinearProgress(energyProgress)

        XCTAssertTrue(startupDashboard.contains("ForEach(presentation.visibleItems)"))
        XCTAssertTrue(startupDashboard.contains("StartupItemRow("))
        XCTAssertFalse(startupDashboard.contains("DisclosureGroup"))
        XCTAssertFalse(startupDashboard.contains("Capsule("))

        let releasePanel = try sourceSegment(
            source,
            from: "private struct MemoryReleasePanel",
            to: "private struct MemoryInlineMetric"
        )
        // Current direction restores real usage and pressure gauges while retaining the full list.
        // D53 (UI-V2-SPEC 1.5): both gauges are the shared MetricRing; usage
        // shows the measured ratio, pressure only its macOS level (a full
        // ring in the level color, the empty track when unavailable).
        XCTAssertTrue(releasePanel.contains("fraction: usedRatio"))
        XCTAssertTrue(releasePanel.contains("fraction: snapshot.reportablePressureLevel == nil ? nil : 1"))
        XCTAssertFalse(releasePanel.contains("Circle()"))
        XCTAssertTrue(releasePanel.contains("private var pressureSummary: some View"))
        XCTAssertTrue(releasePanel.contains("pressureHeadroomText"))
        XCTAssertFalse(releasePanel.contains("MetadataPill("))

        let selectionHeader = try sourceSegment(
            source,
            from: "private struct MemoryAppSelectionTableHeader",
            to: "private struct MemorySelectableAppRow"
        )
        XCTAssertFalse(selectionHeader.contains("RoundedRectangle("))
        XCTAssertFalse(selectionHeader.contains(".background("))

        let selectionRow = try sourceSegment(
            source,
            from: "private struct MemorySelectableAppRow",
            to: "private struct MemoryProcessUsageBar"
        )
        XCTAssertFalse(selectionRow.contains("MetadataPill("))
        XCTAssertFalse(selectionRow.contains("RoundedRectangle("))
        XCTAssertFalse(selectionRow.contains(".background("))

        let memoryProgress = try sourceSegment(
            source,
            from: "private struct MemoryProcessUsageBar",
            to: "private struct ProcessIcon"
        )
        assertNativeLinearProgress(memoryProgress)

        let processIcon = try sourceSegment(
            source,
            from: "private struct ProcessIcon",
            to: "private struct InstalledAppRow"
        )
        XCTAssertFalse(processIcon.contains("Circle("))
        XCTAssertFalse(processIcon.contains(".background("))
        XCTAssertFalse(processIcon.contains(".shadow("))

        let uninstallRow = try sourceSegment(
            source,
            from: "private struct InstalledAppRow",
            to: "private struct InstalledAppIcon"
        )
        XCTAssertTrue(uninstallRow.contains("Button(action: select)"))
        XCTAssertTrue(uninstallRow.contains(".appButtonChrome(.selectionRow)"))
        XCTAssertFalse(uninstallRow.contains("confirmUninstall"))
        XCTAssertTrue(uninstallRow.contains(".contextMenu {"))
        let menuStart = try XCTUnwrap(uninstallRow.range(of: ".contextMenu {")?.lowerBound)
        let menuEnd = uninstallRow.endIndex
        let contextActions = String(uninstallRow[menuStart..<menuEnd])
        XCTAssertTrue(contextActions.contains("store.reveal(app.path)"))
        XCTAssertTrue(contextActions.contains("store.copyPath(app.path)"))
        XCTAssertFalse(contextActions.contains("requestUninstall"))
        XCTAssertFalse(uninstallRow.contains("MetadataPill("))
        XCTAssertFalse(uninstallRow.contains("Capsule("))

        for removedComponent in [
            "UninstallRecommendationPill",
            "InstalledAppInfoLine",
            "VersionComparisonStrip",
            "VersionValueCard",
            "UpdateMethodPill",
        ] {
            XCTAssertFalse(source.contains("struct \(removedComponent)"))
        }
    }

    private func assertNativeLinearProgress(
        _ source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(source.contains("ProgressView(value:"), file: file, line: line)
        XCTAssertTrue(source.contains(".progressViewStyle(.linear)"), file: file, line: line)
        XCTAssertFalse(source.contains("GeometryReader"), file: file, line: line)
        XCTAssertFalse(source.contains("Capsule("), file: file, line: line)
    }

    private func sourceText(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSegment(_ source: String, from start: String, to end: String) throws -> String {
        let suffix = try XCTUnwrap(source.components(separatedBy: start).last)
        return try XCTUnwrap(suffix.components(separatedBy: end).first)
    }
}
