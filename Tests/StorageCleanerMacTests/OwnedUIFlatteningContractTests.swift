import Foundation
import XCTest

final class OwnedUIFlatteningContractTests: XCTestCase {
    func testManagementPagesKeepSelectionSeparateFromExecution() throws {
        let utilities = try sourceText("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let uninstall = try sourceSegment(utilities, from: "struct AppUninstallerView", to: "struct UninstallPreviewSheet")
        let dropStart = try XCTUnwrap(uninstall.range(of: ".dropDestination(for: URL.self)"))
        let dropEnd = try XCTUnwrap(uninstall.range(of: ".help(", range: dropStart.upperBound..<uninstall.endIndex))
        let drop = uninstall[dropStart.lowerBound..<dropEnd.lowerBound]
        XCTAssertTrue(drop.contains("presentation.apps.first"))
        XCTAssertTrue(drop.contains("$0.isFileURL"))
        XCTAssertTrue(drop.contains("PathSafety.lexicalPath(app.path)"))
        XCTAssertTrue(drop.contains("selectedApplicationID = app.id"))
        XCTAssertFalse(drop.contains("requestUninstall"))
        XCTAssertFalse(drop.contains("confirmUninstall"))
        XCTAssertTrue(uninstall.contains("List(selection: $selectedApplicationID)"))
        XCTAssertTrue(uninstall.contains("ForEach(AppUninstallListFilter.allCases)"))
        XCTAssertFalse(uninstall.contains("!store.hasScannedInstalledApps || store.isLoadingInstalledApps"))

        let updates = try sourceText("Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift")
        let manager = try sourceSegment(updates, from: "private struct AppUpdateManagerPage", to: "private struct AppUpdateCatalogRow")
        XCTAssertTrue(manager.contains("selectedAutomaticApplicationIDs.subtracting(visibleAutomaticApplicationIDs).count"))
        XCTAssertTrue(manager.contains("selectedAutomaticApplicationIDs.formUnion(visibleAutomaticApplicationIDs)"))
        XCTAssertTrue(manager.contains("onUpdateAutomatic(selectedAutomaticApplicationIDs)"))
        let initialSelection = try sourceSegment(manager, from: ".onAppear {", to: ".onChange(of: snapshot.sessionID)")
        XCTAssertFalse(initialSelection.contains("selectedAutomaticApplicationIDs ="))
    }

    func testCompactPanelUsesSemanticFlatControlsAndExplicitDirections() throws {
        let source = try sourceText("Sources/StorageCleanerMac/Views/MenuBarStatusView.swift")
        let settings = try sourceText("Sources/StorageCleanerMac/Views/MenuBarPanelSettingsView.swift")
        let chrome = try sourceText("Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift")
        let geekEditor = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDashboardEditor.swift"
        )

        let cleanupOverview = try sourceSegment(
            source,
            from: "private var cleanupOverview: some View",
            to: "private var cleanupGroupRows: some View"
        )
        XCTAssertTrue(cleanupOverview.contains(".font(.title2.weight(.semibold))"))
        XCTAssertFalse(cleanupOverview.contains(".font(.system(size:"))

        let networkSummary = try sourceSegment(
            source,
            from: "private var networkSummaryRow: some View",
            to: "@ViewBuilder\n    private var recommendationSection"
        )
        XCTAssertTrue(networkSummary.contains("AppSymbols.Panel.download"))
        XCTAssertTrue(networkSummary.contains("AppSymbols.Panel.upload"))
        XCTAssertTrue(networkSummary.contains("下载"))
        XCTAssertTrue(networkSummary.contains("上传"))
        XCTAssertTrue(networkSummary.contains(".accessibilityLabel("))
        XCTAssertTrue(networkSummary.contains("let displayValue = networkTransferDisplayValue(value)"))
        XCTAssertTrue(networkSummary.contains(".accessibilityValue(displayValue)"))
        XCTAssertTrue(networkSummary.contains("first == \"↓\" || first == \"↑\""))

        let scanning = try sourceSegment(
            source,
            from: "private var scanningRecommendation: some View",
            to: "@ViewBuilder\n    private func memoryRecommendation"
        )
        XCTAssertFalse(scanning.contains("Button {"))
        XCTAssertFalse(scanning.contains("openAppWindow("))

        let resultBanner = try sourceSegment(
            source,
            from: "private func resultBanner",
            to: "private var memoryBatchQuitAlertBinding"
        )
        XCTAssertFalse(resultBanner.contains(".background("))

        XCTAssertFalse(source.contains("private var footerAction: some View"))
        XCTAssertFalse(source.contains("PanelToolbarActions("))
        XCTAssertTrue(source.contains("PanelHeader("))
        XCTAssertFalse(source.contains("AppIconButton("))
        XCTAssertEqual(chrome.components(separatedBy: "AppIconButton(").count - 1, 1)
        XCTAssertEqual(chrome.components(separatedBy: "kind: .toolbar").count - 1, 1)
        XCTAssertEqual(chrome.components(separatedBy: "Menu {").count - 1, 2)
        XCTAssertTrue(chrome.contains("struct PanelRefreshControl: View"))
        XCTAssertTrue(chrome.contains("L10n.text(\"打开主窗口\", \"Open Main Window\")"))
        XCTAssertTrue(chrome.contains("AppSymbols.Action.showMainWindow"))
        XCTAssertTrue(chrome.contains("AppSymbols.Action.more"))
        XCTAssertTrue(chrome.contains(
            ".accessibilityLabel(L10n.text(\"更多小窗操作\", \"More Panel Actions\"))"
        ))
        XCTAssertFalse(chrome.contains("打开存储清理助手"))
        XCTAssertFalse(chrome.contains("退出存储清理助手"))
        XCTAssertFalse(settings.contains("退出存储清理助手"))

        XCTAssertTrue(source.contains("PanelShell("))
        XCTAssertFalse(source.contains(".appGlassSegmentedControl()"))
        XCTAssertFalse(source.contains("matchedGeometryEffect"))
        XCTAssertFalse(source.contains("@Environment(\\.colorScheme) private var colorScheme"))
        XCTAssertFalse(settings.contains("struct PanelSettingsView: View"))
        XCTAssertFalse(settings.contains("Form {"))
        XCTAssertFalse(geekEditor.contains("Form {"))
        XCTAssertFalse(geekEditor.contains("ScrollView"))
        XCTAssertTrue(geekEditor.contains(".frame(width: 320, height: 500)"))
        XCTAssertTrue(geekEditor.contains(".pickerStyle(.menu)"))
        XCTAssertFalse(geekEditor.contains("刷新频率"))
        XCTAssertFalse(settings.contains("xmark"))
        XCTAssertTrue(chrome.contains(".popover(isPresented: geekEditorBinding"))
        XCTAssertFalse(chrome.contains("Color.gray"))
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
        XCTAssertTrue(releasePanel.contains("progress: usedRatio"))
        XCTAssertTrue(releasePanel.contains("progress: nil"))
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
        XCTAssertTrue(uninstallRow.contains("store.requestUninstall(app)"))
        XCTAssertTrue(uninstallRow.contains(".contextMenu {"))
        let contextActions = try XCTUnwrap(uninstallRow.components(separatedBy: ".contextMenu {").last)
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
