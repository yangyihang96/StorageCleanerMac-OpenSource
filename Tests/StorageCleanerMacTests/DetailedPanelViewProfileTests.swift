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

    func testDetailedOverviewKeepsCoreSignalsAndIgnoresGeekCustomization() {
        var configuration = GeekDashboardConfiguration.defaultValue
        configuration.setModule(.processorGraphics, isVisible: false)
        configuration.setModule(.network, isVisible: false)
        configuration.setModule(.power, isVisible: true)

        XCTAssertEqual(
            GeekPanelContentProfile.reduced.overviewModules(
                configuredModules: configuration.modules
            ),
            [
                .processorGraphics,
                .coreMetrics,
                .disk,
                .network,
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
        XCTAssertTrue(source.contains("L10n.text(\"网络硬盘\", \"Network Drives\")"))
        XCTAssertTrue(source.contains("networkStorageVolumes.map"))
        XCTAssertTrue(source.contains("volume.capacity.userUsedPercent"))
        XCTAssertTrue(source.contains("ByteFormat.storageString(volume.capacity.userAvailableBytes)"))
    }

    func testDiskCascadeKeepsCapacityProgressOnlyInTheOverview() throws {
        let overview = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift"
        )
        let detail = try sourceText(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift"
        )

        XCTAssertTrue(overview.contains("max(0, 1 - storageSnapshot.userUsedRatio)"))
        XCTAssertFalse(detail.contains("GeekDiskUsageRing"))
        XCTAssertTrue(detail.contains("volume.capacity.userUsedPercent"))
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
        XCTAssertTrue(memory.contains("height: showsExtendedGeekDetails ? 119 : 83"))
        XCTAssertTrue(memory.contains("private var memoryProcessActions: some View"))
        XCTAssertTrue(memory.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(network.contains("private var hardwareAddressValue: some View"))
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
        XCTAssertTrue(network.contains("additionalScopedDNSCount"))
        XCTAssertTrue(network.contains("VPNControlCapabilityResolver"))
        XCTAssertTrue(network.contains("tunnel.tunnelIPv4"))
        XCTAssertTrue(network.contains("tunnel.scopedDNSServers"))
        XCTAssertTrue(network.contains("geekNetworkProcessCard"))
        XCTAssertTrue(network.contains("GeekNetworkAddressLine("))
        XCTAssertTrue(network.contains(".truncationMode(.middle)"))
        XCTAssertTrue(network.contains(".help(value)"))
        XCTAssertTrue(network.contains(".accessibilityLabel(\"\\(version), \\(value)\")"))
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
        XCTAssertTrue(overview.contains("attachmentAnchor: .rect(.bounds), arrowEdge: .leading"))
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
        let setSection = try XCTUnwrap(sectionHandler.range(of: "setGeekPanelSection"))
        let setDetailSize = try XCTUnwrap(sectionHandler.range(of: "setGeekPanelDetailSize"))
        XCTAssertLessThan(setSection.lowerBound, setDetailSize.lowerBound)
        XCTAssertTrue(advanced.contains(".onChange(of: presentation)"))
        XCTAssertTrue(advanced.contains("private func resetAttachedPanelNavigation()"))
        XCTAssertTrue(advanced.contains("private func reconcileAttachedPanelAfterDensityChange()"))
        XCTAssertTrue(advanced.contains("activeTertiaryDetail = nil"))
        XCTAssertTrue(advanced.contains("panelCoordinator.reset()"))
        XCTAssertTrue(advanced.contains("selectedRailSection = .overview"))
        XCTAssertTrue(advanced.contains("setGeekPanelSection(selectedSection)"))
    }

    private func sourceText(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let packageRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
