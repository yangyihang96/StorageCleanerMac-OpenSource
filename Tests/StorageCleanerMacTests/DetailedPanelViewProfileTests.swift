import Foundation
import XCTest
@testable import StorageCleanerMac

final class DetailedPanelViewProfileTests: XCTestCase {
    func testDetailedAndGeekDensitiesShareTheAttachedPanelHierarchy() {
        XCTAssertFalse(PanelDensity.simple.usesGeekLayout)
        XCTAssertTrue(PanelDensity.complex.usesGeekLayout)
        XCTAssertTrue(PanelDensity.geek.usesGeekLayout)

        XCTAssertNil(PanelDensity.simple.geekContentProfile)
        XCTAssertEqual(PanelDensity.complex.geekContentProfile, .reduced)
        XCTAssertEqual(PanelDensity.geek.geekContentProfile, .full)
    }

    func testDetailedOverviewHonorsTheSameCustomizationAsGeek() {
        var configuration = GeekDashboardConfiguration.defaultValue
        configuration.setModule(.processorGraphics, isVisible: false)
        configuration.setModule(.network, isVisible: false)
        configuration.setModule(.power, isVisible: true)

        XCTAssertEqual(
            GeekPanelContentProfile.reduced.overviewModules(
                configuredModules: configuration.modules
            ),
            [
                .coreMetrics,
                .disk,
                .sensors,
                .power,
            ]
        )
        XCTAssertFalse(GeekPanelContentProfile.reduced.showsExtendedDetails)
    }

    func testGeekOverviewStillHonorsVisibleCustomizedModules() {
        var configuration = GeekDashboardConfiguration.defaultValue
        configuration.setModule(.network, isVisible: false)
        configuration.modules.append(contentsOf: [
            .init(module: .fans, isVisible: true, width: .full),
            .init(module: .systemLoad, isVisible: true, width: .full),
            .init(module: .cleanupSummary, isVisible: true, width: .full),
            .init(module: .memoryBreakdown, isVisible: true, width: .full),
        ])

        let modules = GeekPanelContentProfile.full.overviewModules(
            configuredModules: configuration.modules
        )

        XCTAssertEqual(
            modules,
            configuration.modules
                .filter { $0.isVisible && $0.module.isAvailableInOverview }
                .map(\.module)
        )
        XCTAssertTrue(modules.allSatisfy(\.isAvailableInOverview))
        XCTAssertTrue(GeekPanelContentProfile.full.showsExtendedDetails)
    }

    func testDetailedPagesKeepGeekHoverTargetsWhileGatingOnlyExtendedCards() throws {
        let root = try sourceText("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(root.contains("GeekAttachedPanelShell("))
        XCTAssertTrue(root.contains("if presentation.usesGeekLayout, selectedSection != .overview"))

        let expectedPrimaryHoverTargets = [
            "GeekProcessorView.swift": "geekProcessorActivityHoverTarget",
            "GeekMemoryView.swift": "geekMemoryHistoryHoverTarget",
            "GeekDiskView.swift": "geekDiskVolumeHoverTarget",
            "GeekNetworkView.swift": "geekNetworkTrend",
            "GeekSensorsView.swift": "geekSensorsGaugeCard",
            "GeekPowerView.swift": "geekPowerGaugeCard",
        ]

        for (file, primaryTarget) in expectedPrimaryHoverTargets {
            let source = try sourceText(
                "Sources/StorageCleanerMac/Views/MenuBarAdvanced/\(file)"
            )
            XCTAssertTrue(source.contains(primaryTarget), file)
            if file == "GeekNetworkView.swift" {
                XCTAssertTrue(source.contains("showsExtendedGeekDetails ? 4 : 2"), file)
            } else if file == "GeekSensorsView.swift" {
                XCTAssertFalse(source.contains("geekFrequencyCard"), file)
                XCTAssertTrue(source.contains("compactFanHistoryRow"), file)
            } else {
                XCTAssertTrue(source.contains("if showsExtendedGeekDetails"), file)
            }
        }
    }

    func testDiskPagePlacesNetworkDrivesBelowTheLocalVolumeList() throws {
        let source = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift"
        )

        let localList = try XCTUnwrap(source.range(of: "geekDiskVolumeList"))
        let networkSection = try XCTUnwrap(source.range(of: "geekNetworkDiskSection"))
        XCTAssertLessThan(localList.lowerBound, networkSection.lowerBound)
        // D138: iStat's 'Disks.Network Disks' (was "网络硬盘", "Network Drives").
        XCTAssertTrue(source.contains("L10n.text(\"网络磁盘\", \"Network Disks\")"))
        XCTAssertTrue(source.contains("GeekDiskVolumePresentation.hasReadableCapacity($0.capacity)"))
        XCTAssertTrue(source.contains("guard Self.hasReadableCapacity(capacity) else { return nil }"))
        XCTAssertTrue(source.contains("return capacity?.userUsedPercent"))
        // D128 (2026-10-19): iStat's disk space format (was
        // `ByteFormat.storageString(capacity.userAvailableBytes)`).
        XCTAssertTrue(source.contains("IStatNumberFormat.space(capacity.userAvailableBytes)"))
    }

    /// Decision D14 (2026-10-04): the level-one bar shows the used share like
    /// the level-two ring. This test was
    /// `testDiskCascadeKeepsOverviewFreeRatioAndRealVolumeCapacity` and locked
    /// the earlier decision, the available share
    /// (`max(0, 1 - storageSnapshot.userUsedRatio)`). The rendered bar width is
    /// measured in `MiniWindowDiskLevelOneBarTests`.
    func testDiskCascadeShowsTheUsedShareOnEveryLevelAndRealVolumeCapacity() throws {
        let overview = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let detail = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift"
        )

        // D118 (2026-10-18): the level-one bar became iStat's capacity ring,
        // filled to the same used share (was
        // `.frame(width: proxy.size.width * storageSnapshot.userUsedRatio)`);
        // `MiniWindowDiskLevelOneBarTests` measures the rendered arc.
        XCTAssertTrue(overview.contains("progress: Self.ringProgress(storageSnapshot)"))
        XCTAssertTrue(overview.contains("storageSnapshot.userUsedRatio"))
        XCTAssertFalse(overview.contains("1 - storageSnapshot.userUsedRatio"))
        XCTAssertFalse(detail.contains("GeekDiskUsageRing"))
        XCTAssertTrue(detail.contains("GeekDiskVolumeCapacityRing(volume: volume"))
        XCTAssertTrue(detail.contains("return capacity?.userUsedPercent"))
        XCTAssertTrue(detail.contains("return capacity?.userUsedRatio"))
        XCTAssertTrue(detail.contains("progress: volume.usageProgress"))
    }

    func testMiniWindowCardsShareBordersAndNarrowHeadersDoNotOverlap() throws {
        let components = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift"
        )
        let memory = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift"
        )
        let network = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift"
        )

        XCTAssertGreaterThanOrEqual(
            components.components(separatedBy: ".geekCardSurface(").count - 1,
            2
        )
        XCTAssertFalse(components.contains(".stroke(\n                    GeekVisualTokens.cardBorder"))
        XCTAssertTrue(memory.contains("ViewThatFits(in: .horizontal)"))
        // D119: the card's minimum is iStat's process section, 25 + 17 per
        // row of its capacity (five or three); was
        // `height: showsExtendedGeekDetails ? 119 : 83`.
        XCTAssertTrue(memory.contains("height: GeekIStatSectionGeometry.processesHeight(geekMemoryProcessCapacity)"))
        XCTAssertEqual(GeekMemoryProcessLayout.rowCapacity(extended: true), 5)
        XCTAssertEqual(GeekMemoryProcessLayout.rowCapacity(extended: false), 3)
        XCTAssertTrue(memory.contains("private var memoryProcessActions: some View"))
        XCTAssertTrue(memory.contains(".fixedSize(horizontal: true, vertical: false)"))
        // D125 (2026-10-19): the MAC address is the interface section's row,
        // its label fixed and its value giving way in the middle (was
        // `hardwareAddressValue` with a "Show" button).
        let interfaceSections = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekIStatInterfaceSections.swift"
        )
        XCTAssertTrue(interfaceSections.contains("struct GeekIStatHardwareAddressRow: View"))
        XCTAssertTrue(network.contains("revealsHardwareAddress: $revealsHardwareAddress"))
        XCTAssertTrue(network.contains("private var wiFiHeaderStatus: some View"))
        XCTAssertTrue(network.contains(".truncationMode(.middle)"))
    }

    func testDetailedNetworkUsesTheGeekPageWithVPNAndPhysicalTopologyRows() throws {
        let network = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift"
        )

        XCTAssertTrue(network.contains("networkTopologySnapshot?.activeVPNTunnel"))
        XCTAssertTrue(network.contains("geekPhysicalNetwork"))
        XCTAssertTrue(network.contains("GeekVPNDisclosure"))
        XCTAssertTrue(network.contains("GeekVPNHoverDetail.preferredSize(for: tunnel)"))
        XCTAssertTrue(network.contains("tunnel.tunnelIPv6"))
        // D125 (2026-10-19): every scoped DNS server is a row (was three and
        // "N more").
        XCTAssertFalse(network.contains("additionalScopedDNSCount"))
        XCTAssertTrue(network.contains("GeekIStatInterfaceModel(tunnel: tunnel)"))
        XCTAssertTrue(network.contains("VPNControlCapabilityResolver"))
        XCTAssertTrue(network.contains("tunnel.tunnelIPv4"))
        XCTAssertTrue(network.contains("tunnel.scopedDNSServers"))
        XCTAssertTrue(network.contains("geekNetworkProcessCard"))
        // D140 (2026-10-19): iStat's IP sections, every listed address a row
        // that wraps and copies (were `GeekNetworkAddressLine(`, `.help(value)`
        // and `.accessibilityLabel("\(version), \(value)")`).
        XCTAssertFalse(network.contains("GeekNetworkAddressLine("))
        XCTAssertTrue(network.contains("GeekIStatIPSection("))
        XCTAssertTrue(network.contains(".truncationMode(.middle)"))
        XCTAssertFalse(network.contains(".help(value)"))
        XCTAssertFalse(network.contains(".accessibilityLabel(\"\\(version), \\(value)\")"))
        XCTAssertFalse(network.contains("GeekNetworkInterfaceDisclosure"))
        XCTAssertFalse(network.contains("minimumScaleFactor"))
    }

    func testSecondaryDetailMeasuresCompleteModuleWithoutScrolling() throws {
        let panel = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let overview = try XCTUnwrap(
            panel.components(separatedBy: "var geekOverviewPage: some View").last?
                .components(separatedBy: "    private var showsOverviewPowerModule").first
        )
        let detail = try XCTUnwrap(
            panel.components(separatedBy: "var geekSelectedDetailPage: some View").last?
                .components(separatedBy: "    var geekCanvas").first
        )

        XCTAssertTrue(overview.contains("geekCanvas"))
        XCTAssertFalse(overview.contains("ScrollView"))
        XCTAssertFalse(detail.contains("ScrollView"))
        XCTAssertTrue(detail.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(detail.contains("GeekDetailContentMeasurement("))
        XCTAssertTrue(detail.contains("section: measuredSection"))
        XCTAssertTrue(detail.contains("density: measuredDensity"))
        XCTAssertFalse(detail.contains("geekDetailFooter"))
        XCTAssertFalse(detail.contains("Open Main Window"))
    }

    func testGeekOverviewUsesActionsWithoutRestoringTheOldHeader() throws {
        let root = try sourceText("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")

        XCTAssertFalse(root.contains("isGeekOverviewHovering"))
        let overview = try sourceText("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        XCTAssertFalse(overview.contains("overviewToolbarHeight"))
        // The CPU time picker is a sibling overlay; the removed overview toolbar stays absent.
        XCTAssertFalse(overview.contains("overviewToolbar"))
        XCTAssertTrue(overview.contains(".contextMenu { overviewContextMenu }"))
        XCTAssertFalse(overview.contains("GeekDashboardEditor(state:"))
        XCTAssertFalse(root.contains(".background(.bar)"))
        XCTAssertFalse(root.contains("forcesGeekOverviewToolbar"))
    }

    func testGeekOnlySceneOpensAtOverviewWithoutDensitySwitching() throws {
        let scene = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarStatusPanelRoot.swift"
        )
        XCTAssertTrue(scene.contains("initialSection: .overview"))
        XCTAssertFalse(scene.contains("initialSection: panelSettingsState.selectedSection"))
        XCTAssertFalse(scene.contains("if density.usesAttachedDetailPresentation"))
        XCTAssertFalse(scene.contains("case .complex, .geek:"))
        XCTAssertFalse(scene.contains("presentation: panelDensity"))
        XCTAssertTrue(scene.contains("presentation: .geek"))
        XCTAssertTrue(scene.contains(".id(languageRawValue)"))
        XCTAssertFalse(scene.contains(".id(languageRawValue + appearanceRawValue)"))
        XCTAssertFalse(scene.contains("appearanceRawValue + densityRawValue"))

        let shell = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"
        )
        XCTAssertTrue(shell.contains("let density: PanelDensity"))
        XCTAssertTrue(shell.contains("normalizedDetailSize(\n            detailPreferredSize,"))
        XCTAssertTrue(shell.contains("GeekPanelPresentationMetrics.expandedSize("))
        XCTAssertTrue(shell.contains("density: density"))

        let advanced = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"
        )
        XCTAssertTrue(advanced.contains("density: presentation"))
        XCTAssertTrue(advanced.contains("@State var measuredDetailContentMeasurement: GeekDetailContentMeasurement?"))
        XCTAssertTrue(advanced.contains("measurement.section == selectedSection"))
        let sectionChange = try XCTUnwrap(
            advanced.range(of: ".onChange(of: selectedSection)")
        )
        let sectionHandlerTail = advanced[sectionChange.lowerBound...]
        let nextHandler = try XCTUnwrap(
            sectionHandlerTail.range(of: ".onChange(of: hasActiveTertiary)")
        )
        let sectionHandler = sectionHandlerTail[..<nextHandler.lowerBound]
        XCTAssertTrue(sectionHandler.contains("setGeekPanelSection("))
        XCTAssertTrue(sectionHandler.contains("preferredDetailSize: selectedSection == .overview ? nil : activeDetailPreferredSize"))
        XCTAssertFalse(sectionHandler.contains("setGeekPanelDetailSize("),
                       "A hover route must not commit a second layout before content measurement")
        XCTAssertTrue(advanced.contains(".onChange(of: presentation)"))
        XCTAssertTrue(advanced.contains("private func resetAttachedPanelNavigation()"))
        XCTAssertTrue(advanced.contains("private func reconcileAttachedPanelAfterDensityChange()"))
        XCTAssertTrue(advanced.contains("activeTertiaryDetail = nil"))
        XCTAssertTrue(advanced.contains("panelCoordinator.reset()"))
        XCTAssertFalse(advanced.contains("selectedRailSection"))
        XCTAssertTrue(advanced.contains("setGeekPanelSection(\n            selectedSection,"))
    }

    private func sourceText(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let packageRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let value = try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
        if relativePath.hasSuffix("/MenuBarGeekPanel.swift") {
            let presentationURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekOverviewPresentation.swift")
            return value + "\n" + (try String(contentsOf: presentationURL, encoding: .utf8))
        }
        return value
    }
}
