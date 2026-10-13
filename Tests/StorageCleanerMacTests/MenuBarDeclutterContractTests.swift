import Foundation
import XCTest
@testable import StorageCleanerMac

/// D64: source evidence always comes from the actual live views. Deleted
/// layouts must stay absent; this fixture never redirects a missing file.
enum D64MenuBarSource {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static let retiredFiles = [
        "MenuBarStatusView.swift",
        "MenuBarAdvanced/MenuBarCombinedPanel.swift",
        "MenuBarAdvanced/MenuBarDiskPanel.swift",
        "MenuBarAdvanced/MenuBarPowerPanel.swift",
        "MenuBarAdvanced/MenuBarMemoryPanel.swift",
        "MenuBarAdvanced/MenuBarNetworkPanel.swift",
        "MenuBarAdvanced/MenuBarProcessorPanel.swift",
        "MenuBarAdvanced/MenuBarSensorsPanel.swift",
    ]

    static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/" + path), encoding: .utf8)
    }

    static func containsLabelRenderer(in source: String) -> Bool {
        source.range(of: #"\bLabel\s*[({]"#, options: .regularExpression) != nil
    }

    static func liveSources() throws -> String {
        let folder = root.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvanced")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        return try ([source("MenuBarAdvancedStatusView.swift"), source("MenuBarPanelChrome.swift")]
            + files.map { try String(contentsOf: $0, encoding: .utf8) }).joined(separator: "\n")
    }
}

final class MenuBarDeclutterContractTests: XCTestCase {
    func testBackButtonsKeepTheSameNavigationArrowAndStyle() throws {
        let palette = try D64MenuBarSource.source("MenuBarAdvanced/ControlPaletteViews.swift")
        let chrome = try D64MenuBarSource.source("MenuBarPanelChrome.swift")
        let curve = try r2SourceDeclaration("private var fanCurveEditor:", in: palette)
        let compact = try r2SourceDeclaration("private func compactSurface(", in: chrome)
        for surface in [curve, compact] {
            let end = try XCTUnwrap(surface.range(of: "Spacer(minLength:"))
            let backButton = String(surface[..<end.lowerBound])
            XCTAssertTrue(backButton.contains("systemImage: \"chevron.backward\""))
            XCTAssertTrue(backButton.contains(".labelStyle(.titleAndIcon)"))
            XCTAssertTrue(backButton.contains(".buttonStyle(ResponsivePlainButtonStyle())"))
            XCTAssertTrue(backButton.contains(".font(AdvancedPanelTypography.captionStrong)"))
            XCTAssertTrue(backButton.contains(".controlSize(.small)"))
        }
        XCTAssertTrue(curve.contains("presentation.showFanControls()"))
        XCTAssertTrue(curve.contains(".accessibilityLabel(L10n.text(\"返回风扇控制\", \"Back to Fan Control\"))"))
        XCTAssertTrue(compact.contains("hoverCoordinator?.dismissHistory()"))
        XCTAssertTrue(compact.contains("hoverCoordinator?.reset()"))
    }

    func testCompactFanSyncUsesOneFullWidthHeaderOutsideSliderBranches() throws {
        let controls = try D64MenuBarSource.source("MenuBarAdvanced/FanControlInlineControls.swift")
        let manual = try r2SourceDeclaration("struct FanManualSliderList:", in: controls)
        let body = try r2SourceDeclaration("var body: some View", in: manual)
        XCTAssertTrue(body.contains("compactFanHeader"))
        XCTAssertTrue(body.contains("manualSlider"))
        XCTAssertFalse(body.contains("draft.synchronizesFans"))
        XCTAssertTrue(body.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        let header = try r2SourceDeclaration("private var compactFanHeader:", in: manual)
        XCTAssertTrue(header.contains("if !draft.synchronizesFans"))
        XCTAssertTrue(header.contains("compactTargetFanMenu(reading: reading)"))
        XCTAssertTrue(header.contains("FanSyncToggleRow(draft: $draft, isDisabled: isDisabled)"))
        XCTAssertTrue(header.contains(".frame(maxWidth: .infinity, minHeight: MiniWindowStyleTokens.dataRowHeight, alignment: .trailing)"))
        let slider = try r2SourceDeclaration("private func sliderRow", in: manual)
        XCTAssertFalse(slider.contains("FanSyncToggleRow("))
        XCTAssertEqual(manual.components(separatedBy: "FanSyncToggleRow(").count - 1, 1)
        let toggle = try r2SourceDeclaration("struct FanSyncToggleRow:", in: controls)
        XCTAssertTrue(toggle.contains(".frame(maxWidth: .infinity, minHeight: MiniWindowStyleTokens.controlRowHeight, alignment: .trailing)"))
        XCTAssertTrue(toggle.contains(".layoutProbe(\"fan.sync.toggle\")"))
        XCTAssertTrue(toggle.contains("draft.setSynchronized(!draft.synchronizesFans)"))
        XCTAssertTrue(toggle.contains(".accessibilityValue(draft.synchronizesFans"))
        let menu = try r2SourceDeclaration("private func compactTargetFanMenu", in: manual)
        XCTAssertTrue(menu.contains(".frame(width: 80)"))
        XCTAssertTrue(menu.contains(".help(presentation.fullName)"))
        XCTAssertTrue(menu.contains(".tag(fan.index)"))
    }

    @MainActor
    func testGeekSelectionAndPreviewUseCoordinatorRouteWithoutLegacyRailState() throws {
        let geek = try D64MenuBarSource.source("MenuBarAdvanced/MenuBarGeekPanel.swift")
        let root = try D64MenuBarSource.source("MenuBarAdvancedStatusView.swift")
        XCTAssertFalse(geek.contains("selectedRailSection"))
        XCTAssertFalse(root.contains("selectedRailSection"))
        let section = try r2SourceDeclaration("var selectedSection:", in: root)
        XCTAssertTrue(section.contains("get { panelCoordinator.selectedSection }"))
        XCTAssertTrue(section.contains("panelCoordinator.selectModule(newValue)"))
        for (marker, call) in [
            ("func selectGeekSection", "panelCoordinator.selectModule(section)"),
            ("func previewGeekSection", "panelCoordinator.previewModule(section)"),
            ("func selectGeekHardwareDetail", "panelCoordinator.selectHardwareDetail(focus)"),
            ("func previewGeekHardwareDetail", "panelCoordinator.previewHardwareDetail(focus)"),
        ] {
            let action = try r2SourceDeclaration(marker, in: geek)
            XCTAssertTrue(action.contains(call), marker)
        }

        // Exercise the shared route owner without constructing a store or
        // querying live hardware. Hover must not replace a pinned selection.
        let coordinator = GeekPanelCoordinator(pointerLocationProvider: { .zero })
        for destination in PanelSection.allCases where destination != .overview {
            coordinator.reset()
            coordinator.previewModule(destination)
            XCTAssertEqual(coordinator.route, .module(destination))
            XCTAssertEqual(coordinator.selectedSection, destination)
            XCTAssertFalse(coordinator.isModulePinned)
            coordinator.selectModule(destination)
            XCTAssertEqual(coordinator.selectedSection, destination)
            XCTAssertTrue(coordinator.isModulePinned)
            let other: PanelSection = destination == .memory ? .processor : .memory
            coordinator.previewModule(other)
            XCTAssertEqual(coordinator.route, .module(destination))
            coordinator.selectModule(.overview)
            XCTAssertEqual(coordinator.route, .summary)
            XCTAssertEqual(coordinator.selectedSection, .overview)
            XCTAssertFalse(coordinator.isModulePinned)
        }
        for focus in [GeekHardwareDetailFocus.monitoring, .power] {
            coordinator.reset()
            coordinator.previewHardwareDetail(focus)
            XCTAssertEqual(coordinator.route, .module(.sensors))
            XCTAssertEqual(coordinator.selectedSection, .sensors)
            XCTAssertEqual(coordinator.hardwareDetailFocus, focus)
            XCTAssertFalse(coordinator.isModulePinned)
            coordinator.selectHardwareDetail(focus)
            XCTAssertEqual(coordinator.route, .module(.sensors))
            XCTAssertEqual(coordinator.hardwareDetailFocus, focus)
            XCTAssertTrue(coordinator.isModulePinned)
            coordinator.selectHardwareDetail(focus)
            XCTAssertEqual(coordinator.route, .summary)
            XCTAssertFalse(coordinator.isModulePinned)
        }
    }

    func testRetiredPanelFilesAndUnreachableBuildersStayAbsent() throws {
        for path in D64MenuBarSource.retiredFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                D64MenuBarSource.root.appendingPathComponent("Sources/StorageCleanerMac/Views/" + path).path), path)
        }
        let live = try D64MenuBarSource.liveSources()
        for declaration in [
            "struct MenuBarStatusView:", "struct PanelHeader:", "var moduleRail:", "var detailPage:",
            "var geekFansCard:", "var geekSystemLoadCard:", "struct GeekHardwareAuthorizationCard:",
            "struct GeekHistoryCoverageRow:", "struct GeekEnergyModeOptionRow:",
            "enum MenuBarRecommendedAppsQuit",
        ] {
            XCTAssertFalse(live.contains(declaration), declaration)
        }
        let root = try D64MenuBarSource.source("MenuBarAdvancedStatusView.swift")
        let boundary = try r2SourceDeclaration("private var liveCurrentContent: AnyView", in: root)
        XCTAssertTrue(boundary.contains("geekDetailPage"))
        XCTAssertFalse(boundary.contains("MenuBarObservedObjectBoundary"))
        XCTAssertFalse(boundary.contains("switch selectedSection"))
        XCTAssertTrue(try D64MenuBarSource.source("MenuBarStatusPanelRoot.swift").contains("presentation: .geek"))
    }

    func testRetiredPanelDependenciesHaveNoDeclarations() throws {
        let retired: [(String, [String])] = [
            ("Sources/StorageCleanerMac/Models/SystemMonitorModels.swift", [
                "simpleChoices", "simpleTitle",
            ]),
            ("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHardwareControlView.swift", [
                "authorizationHeight",
            ]),
            ("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift", [
                "GeekSection",
            ]),
            ("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift", [
                "hasCachedDiskHealth", "hasCachedNetworkSpeedTest", "hasCachedBatteryHealth",
                "capacitySevenDayDeltaText", "diskSMARTStatusTint", "capacityDeltaTint",
                "speedMbpsText", "batteryCapacityTint", "batteryConditionTint",
                "updatedUnavailableText", "selectedSectionUpdatedAt", "percentProgress",
                "processorTopologyText", "processorClusterTitle", "processorVoltageText",
                "processorClusterTint", "processorChartSeries", "memoryPressureStateProgress",
                "memoryPressureHeadroomText", "storagePercentText", "thermalStateTint",
                "networkRelativeProgress", "sensorTiles", "actionableMemoryApps",
                "AdvancedMetricTile", "AdvancedCompactGauge", "AdvancedPlainMetric",
                "AdvancedProcessorClusterRow", "AdvancedAppUsageRow", "AdvancedEnergyAppRow",
                "processMemorySnapshot", "metricDetail", "networkDownPeak",
                "networkUpPeak", "AdvancedNetworkDirection", "AdvancedAppIcon",
                "batterySystemImage", "metricColumns", "timestampText",
                "loadAverage",
            ]),
            ("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift", [
                "geekTopProcesses", "geekDiskReadIOPSText", "geekDiskWriteIOPSText",
                "geekNetworkDownAverage", "geekNetworkUpAverage", "geekAverageRate",
            ]),
            ("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift", [
                "tertiaryDetailButton", "tertiaryButtonHoverChanged", "presentTertiaryDetail",
                "presentFanCurveEditor",
            ]),
            ("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift", [
                "hoveredTertiaryButton",
            ]),
            ("Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift", [
                "navigationWidth", "shortTime", "chineseShortTimeFormatter",
                "englishShortTimeFormatter",
            ]),
        ]
        for (path, names) in retired {
            let source = try String(contentsOf: D64MenuBarSource.root.appendingPathComponent(path), encoding: .utf8)
            for name in names {
                let pattern = #"\b(?:var|let|func|struct|enum|class)\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
                XCTAssertNil(source.range(of: pattern, options: .regularExpression), "\(path): \(name)")
            }
        }
    }

    func testSectionTitlesHaveHeaderTraitsWithoutDecorativeGlyphs() throws {
        for (path, marker) in [
            ("MenuBarAdvanced/MenuBarAdvancedComponents.swift", "struct AdvancedPanelCard<"),
        ] {
            let section = try r2SourceDeclaration(marker, in: D64MenuBarSource.source(path))
            XCTAssertTrue(section.contains("Text(title)"))
            XCTAssertTrue(section.contains(".accessibilityAddTraits(.isHeader)"))
            XCTAssertFalse(D64MenuBarSource.containsLabelRenderer(in: section))
            XCTAssertFalse(section.contains("systemImage"))
            XCTAssertFalse(section.contains("tint"))
            for renderer in ["Image(", "AppSymbol", "GeekModuleLabel", "GeekModuleIcon"] {
                XCTAssertFalse(section.contains(renderer), "\(marker): \(renderer)")
            }
        }
        let components = try D64MenuBarSource.source("MenuBarAdvanced/GeekPanelComponents.swift")
        XCTAssertFalse(components.contains("struct GeekSection<"))
        let header = try r2SourceDeclaration("struct GeekModuleHeader<", in: components)
        XCTAssertTrue(header.contains("GeekModuleLabel(systemImage:"), "D64 #2 keeps the clickable module identity")
        let live = try D64MenuBarSource.liveSources()
        XCTAssertTrue(live.contains("GeekOverviewModuleButton(destination:"))
        XCTAssertTrue(live.contains("CachedAppIconView("))
        XCTAssertTrue(live.contains("struct GeekDisclosureIcon:"))
    }

    func testMenusKeepActionsAndAXLabelsWithoutRepeatedIcons() throws {
        let chrome = try D64MenuBarSource.source("MenuBarPanelChrome.swift")
        let refresh = try r2SourceDeclaration("var menuContents: some View", in: chrome)
        let context = try r2SourceDeclaration("var contextMenuContents: some View", in: chrome)
        let more = try r2SourceDeclaration("private var moreMenuContents: some View", in: chrome)
        for menu in [refresh, context, more] {
            XCTAssertFalse(D64MenuBarSource.containsLabelRenderer(in: menu))
            XCTAssertFalse(menu.contains("AppSymbol"))
            XCTAssertFalse(menu.contains("Image("))
        }
        XCTAssertTrue(refresh.contains("refresh()"))
        XCTAssertTrue(refresh.contains(".disabled(isRefreshing)"))
        XCTAssertTrue(refresh.contains("Toggle(interval.pickerTitle"))
        XCTAssertTrue(context.contains("Button(action: togglePause)"))
        XCTAssertTrue(context.contains("Text(pauseTitle)"))
        XCTAssertTrue(more.contains("openSettings()"))
        XCTAssertTrue(more.contains("Button(action: showMainWindow)"))
        XCTAssertTrue(more.contains("MenuBarStatusController.shared.dismissPanel()"))
        XCTAssertTrue(chrome.contains("systemImage: pauseSystemImage"))
        XCTAssertTrue(chrome.contains("AppSymbols.Action.refresh, role: .toolbar"))
        XCTAssertTrue(chrome.contains("AppSymbols.Action.more, role: .toolbar"))
        XCTAssertTrue(chrome.contains(".accessibilityLabel(L10n.text(\"更多小窗操作\", \"More Panel Actions\"))"))
        XCTAssertTrue(chrome.contains("systemImage: \"chevron.backward\""))
    }

    func testStatusAndSummaryRowsKeepDataWithoutDecoration() throws {
        let components = try D64MenuBarSource.source("MenuBarAdvanced/MenuBarAdvancedComponents.swift")
        for marker in ["struct MiniWindowPausedSamplingRow:", "struct AdvancedUnavailableRow:", "struct AdvancedCleanupItemRow:"] {
            let row = try r2SourceDeclaration(marker, in: components)
            XCTAssertTrue(row.contains("Text("))
            XCTAssertFalse(row.contains("AppSymbol"))
            XCTAssertFalse(D64MenuBarSource.containsLabelRenderer(in: row))
        }
        XCTAssertTrue(components.contains("Automatic Refresh Paused"))
        XCTAssertTrue(components.contains("AppDesignTokens.Palette.warning.opacity(0.08)"))
        let cleanup = try D64MenuBarSource.source("MenuBarAdvanced/GeekCleanupView.swift")
        let row = try r2SourceDeclaration("struct AdvancedSmartCleanupItemRow:", in: cleanup)
        XCTAssertTrue(row.contains("candidate.sourceURL.lastPathComponent"))
        XCTAssertTrue(row.contains("CleanupMeasurementPresentation.value(candidate)"))
        XCTAssertTrue(row.contains(".cleanupItemReadback("))
        XCTAssertFalse(row.contains("AppSymbol"))
        XCTAssertTrue(components.contains("需重新扫描后才能清理"))
        XCTAssertTrue(components.contains("Rescan before cleanup"))
        let power = try r2SourceDeclaration("private func geekPowerSamplingRow", in:
            D64MenuBarSource.source("MenuBarAdvanced/GeekPowerView.swift"))
        XCTAssertFalse(power.contains("AppSymbol"))
        let empty = try r2SourceDeclaration("struct GeekHoverUnavailableState:", in:
            D64MenuBarSource.source("MenuBarAdvanced/GeekHoverDetailTarget.swift"))
        XCTAssertFalse(empty.contains("AppSymbol"))
        XCTAssertTrue(empty.contains("Text(text)"))
    }

    func testTextActionsAndResultCardsKeepSelectionConfirmationAndSafety() throws {
        let memory = try D64MenuBarSource.source("MenuBarAdvanced/GeekMemoryView.swift")
        let action = try r2SourceDeclaration("struct GeekMemoryQuitSelectedButton", in: memory)
        XCTAssertFalse(D64MenuBarSource.containsLabelRenderer(in: action))
        XCTAssertFalse(action.contains("xmark.circle.fill"))
        XCTAssertTrue(action.contains("GeekMemoryQuitSelection.request(store: store)"))
        XCTAssertTrue(action.contains(".accessibilityLabel(GeekMemoryQuitSelection.title)"))
        XCTAssertTrue(action.contains(".disabled(!GeekMemoryQuitSelection.isAvailable(store: store))"))
        let result = try r2SourceDeclaration("private struct GeekMemoryQuitResultCard:", in: memory)
        XCTAssertFalse(result.contains("checkmark.seal.fill"))
        XCTAssertFalse(D64MenuBarSource.containsLabelRenderer(in: result))
        XCTAssertTrue(result.contains("Image(systemName: \"arrow.right\")"))
        XCTAssertTrue(result.contains("targetResults"))
        XCTAssertTrue(memory.contains("Text(summary.confirmationMessage)"))
        XCTAssertTrue(memory.contains("systemImage: isSelected ? \"checkmark.circle.fill\" : \"circle\""))
        let cleanup = try r2SourceDeclaration("struct GeekCleanupActions:", in:
            D64MenuBarSource.source("MenuBarAdvanced/GeekCleanupView.swift"))
        XCTAssertEqual(cleanup.components(separatedBy: "AppButton(").count - 1, 3)
        XCTAssertFalse(cleanup.contains("systemImage:"))
        let curve = try D64MenuBarSource.source("FanCurveEditor.swift")
        XCTAssertFalse(curve.contains("根据温度自动调节风扇转速"))
        XCTAssertFalse(curve.contains("Automatically adjust fan speed from temperature"))
        let edits = try r2SourceDeclaration("private var editActions:", in: curve)
        XCTAssertFalse(D64MenuBarSource.containsLabelRenderer(in: edits))
        XCTAssertTrue(edits.contains("session.addPoint(undoManager: undoManager)"))
        XCTAssertTrue(edits.contains("session.removePoint(id: selectedPointID, undoManager: undoManager)"))
        XCTAssertTrue(curve.contains("0% 对应最低转速"))
        XCTAssertTrue(curve.contains("经 Helper 验证后才会改变实际风扇转速"))
    }

    func testAlwaysVisibleMeasurementCopyIsGoneAndDeepSourcesRemain() throws {
        let memory = try D64MenuBarSource.source("MenuBarAdvanced/GeekMemoryView.swift")
        let swap = try r2SourceDeclaration("private var geekMemorySwapCard:", in: memory)
        XCTAssertFalse(swap.contains("detail: geekSwapExplanation"))
        XCTAssertFalse(swap.contains("detail:"))
        XCTAssertTrue(swap.contains("memorySnapshot.map(swapUsageText)"))
        XCTAssertTrue(swap.contains(".help(geekSwapExplanation)"))
        let sensors = try D64MenuBarSource.source("MenuBarAdvanced/GeekSensorsView.swift")
        for evidence in ["测量值，不是协商功率", "Measured input power from the adapter (not the negotiated rating)", "依据键名推断"] {
            XCTAssertTrue(sensors.contains(evidence), "D64 #10 preserves level-three source notes: \(evidence)")
        }
        let palette = try D64MenuBarSource.source("MenuBarAdvanced/ControlPaletteViews.swift")
        let mode = try r2SourceDeclaration("struct FanControlModeCard:", in: palette)
        XCTAssertTrue(mode.contains("AppSymbolGlyph(systemImage: choice.systemImage"))
        XCTAssertTrue(mode.contains("FanControlModeSelectionMark("))
        let body = try r2SourceDeclaration("var body: some View", in: mode)
        XCTAssertFalse(body.contains("Text(choice.subtitle)\n"))
        XCTAssertFalse(body.contains("fan.mode.subtitle"))
        XCTAssertTrue(mode.contains(".accessibilityHint(Text(isDisabled ? (disabledReason ?? choice.subtitle) : choice.subtitle))"))
    }

    func testNetworkTypeAndWarningsKeepTheirMeaningWithoutTitleDecoration() throws {
        let disk = try D64MenuBarSource.source("MenuBarAdvanced/GeekDiskView.swift")
        let volume = try r2SourceDeclaration("struct GeekDiskVolumeSummary:", in: disk)
        XCTAssertTrue(volume.contains("if volume.isNetwork {"))
        XCTAssertTrue(volume.contains("systemImage: AppSymbols.Panel.networkGlobe"))
        XCTAssertFalse(volume.contains("AppSymbols.Monitor.storage"))
        let network = try D64MenuBarSource.source("MenuBarAdvanced/GeekNetworkView.swift")
        let vpn = try r2SourceDeclaration("struct GeekVPNHoverDetail", in: network)
        XCTAssertFalse(vpn.contains("systemImage: \"lock.shield\""))
        XCTAssertTrue(vpn.contains("vpnStatusText(tunnel.status)"))
        XCTAssertTrue(network.contains("GeekModuleIcon(systemImage: symbol"))
        let hardware = try D64MenuBarSource.source("MenuBarAdvanced/ControlPaletteViews.swift")
        XCTAssertTrue(hardware.contains("clock.badge.exclamationmark"))
        XCTAssertTrue(hardware.contains("exclamationmark.shield"))
        XCTAssertTrue(hardware.contains("Preview · Fan Controls Disabled"))
        let control = try D64MenuBarSource.source("MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        let charge = try r2SourceDeclaration("private var fullChargeButton:", in: control)
        XCTAssertFalse(charge.contains("Image("))
        XCTAssertTrue(charge.contains("GeekDisclosureIcon("))
        XCTAssertTrue(charge.contains("requestFullCharge()"))
    }
}
