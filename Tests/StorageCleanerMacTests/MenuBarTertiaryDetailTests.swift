import XCTest
@testable import StorageCleanerMac

final class MenuBarTertiaryDetailTests: XCTestCase {
    func testEveryReadOnlySystemSectionMapsToOneTertiaryDetail() {
        XCTAssertEqual(PanelSection.processor.tertiaryDetail, .processor)
        XCTAssertEqual(PanelSection.memory.tertiaryDetail, .memory)
        XCTAssertEqual(PanelSection.disk.tertiaryDetail, .disk)
        XCTAssertEqual(PanelSection.network.tertiaryDetail, .network)
        XCTAssertEqual(PanelSection.sensors.tertiaryDetail, .sensors)
        XCTAssertEqual(PanelSection.power.tertiaryDetail, .power)
        XCTAssertNil(PanelSection.overview.tertiaryDetail)
        XCTAssertNil(PanelSection.cleanup.tertiaryDetail)
        XCTAssertEqual(MenuBarTertiaryDetail.allCases.count, 7)
        XCTAssertTrue(MenuBarTertiaryDetail.allCases.contains(.fanCurve))
    }

    func testTertiaryColumnUsesTheSameHeaderlessContentChromeAsTheFirstTwoLevels() throws {
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let network = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")
        let chrome = try XCTUnwrap(
            detail.components(separatedBy: "    private func tertiaryDetailChrome<Content: View>(").last?
                .components(separatedBy: "    @ViewBuilder\n    private func tertiaryDetailBody").first
        )

        XCTAssertTrue(detail.contains("tertiaryDetailChrome(detail: detail, density: presentation)"))
        XCTAssertTrue(detail.contains("requestID: request.id"))
        XCTAssertTrue(detail.contains("density: presentation"))
        XCTAssertTrue(detail.contains("contentPadding: 0"))
        XCTAssertTrue(chrome.contains("ScrollView(.vertical)"))
        XCTAssertTrue(chrome.contains(".environment(\\.advancedValueRowUsesUniformTextSize, true)"))
        XCTAssertFalse(network.contains(".font(.system(size: 11, weight: .regular, design: .monospaced))"))
        XCTAssertTrue(detail.contains(".accessibilityLabel(detail.title)"))
        XCTAssertTrue(detail.contains(".accessibilityLabel(request.accessibilityLabel)"))
        XCTAssertFalse(detail.contains("title: detail.title"))
        XCTAssertFalse(detail.contains("title: request.accessibilityLabel"))
        XCTAssertFalse(chrome.contains("Label("))
        XCTAssertFalse(chrome.contains("Button("))
        XCTAssertFalse(chrome.contains("Divider()"))
        XCTAssertFalse(chrome.contains("frame(height: 36)"))
        XCTAssertFalse(chrome.contains("title: String"))
        XCTAssertFalse(chrome.contains("systemImage: String"))
        XCTAssertFalse(chrome.contains("close:"))
        XCTAssertFalse(detail.contains("Button(L10n.text(\"关闭\", \"Close\"))"))
        XCTAssertFalse(detail.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertFalse(detail.contains("Close Deep Detail"))
        XCTAssertFalse(detail.contains("关闭三级详情"))
    }

    func testTertiarySurfaceUsesTheAttachedThirdColumnAndRealExistingTelemetry() throws {
        let root = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let geek = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        let memory = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        let memoryPanel = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarMemoryPanel.swift")
        let network = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")

        XCTAssertTrue(root.contains("@State var activeTertiaryDetail: MenuBarTertiaryDetail?"))
        XCTAssertTrue(root.contains("tertiaryDetailButton(detail)"))
        XCTAssertFalse(geek.contains("tertiaryDetailButton(detail, compact: true)"))
        XCTAssertTrue(root.contains("activeTertiaryDetail = nil"))
        XCTAssertTrue(root.contains("tertiaryDetailRootHost {"))
        XCTAssertTrue(root.contains("var hasActiveTertiary: Bool"))
        XCTAssertTrue(root.contains("showsTertiary: hasActiveTertiary"))
        XCTAssertTrue(root.contains("tertiaryDetailColumnSurface"))
        XCTAssertTrue(root.contains("private func synchronizeTertiaryPresentation()"))
        XCTAssertTrue(root.contains("preferredSize: activeTertiaryPreferredSize"))
        XCTAssertTrue(root.contains("sourceOffset: activeTertiarySourceOffset"))
        XCTAssertFalse(detail.contains(".popover("))
        XCTAssertFalse(detail.contains("tertiaryPopoverBinding"))
        XCTAssertFalse(detail.contains("popoverArrowEdge"))
        XCTAssertFalse(detail.contains(".replacement"))
        XCTAssertTrue(detail.contains("var tertiaryDetailColumnSurface"))
        XCTAssertTrue(detail.contains("tertiaryDetailSurface(detail)"))
        XCTAssertTrue(detail.contains("tertiaryRequestSurface(request)"))
        XCTAssertTrue(detail.contains("panelSettingsState.tertiaryPresentationMode == .column"))
        XCTAssertTrue(detail.contains("panelSettingsState.tertiaryPresentationMode == .unavailable"))
        XCTAssertTrue(detail.contains(".disabled(panelSettingsState.tertiaryPresentationMode == .unavailable)"))
        XCTAssertTrue(detail.contains(".onContinuousHover"))
        XCTAssertTrue(detail.contains("request.hoverChanged(true)"))
        XCTAssertTrue(detail.contains("request.hoverChanged(false)"))
        XCTAssertTrue(detail.contains("scheduleTertiaryDetailDismissal(detail)"))
        XCTAssertTrue(detail.contains("panelCoordinator.scheduleHoverDismissal("))
        XCTAssertTrue(detail.contains("!geekPanelHoverActivityState.keepsPanelExpanded"))
        XCTAssertFalse(detail.contains("Task.sleep(for:"))
        XCTAssertTrue(detail.contains("GeekPrecisionLineChart("))
        XCTAssertTrue(root.contains("var memoryHistory: [MenuBarTelemetryPoint]"))
        XCTAssertTrue(memory.contains("points: memoryHistory"))
        XCTAssertTrue(memoryPanel.contains("points: memoryHistory"))
        XCTAssertTrue(detail.contains("points: memoryHistory"))
        XCTAssertTrue(detail.contains("channel: .memoryPressure"))
        XCTAssertTrue(detail.contains("channel: .compressedMemoryBytes"))
        XCTAssertTrue(detail.contains("channel: .swapUsedBytes"))
        XCTAssertTrue(detail.contains("unit: .bytes"))
        XCTAssertTrue(detail.contains("channel: .gpuTemperature"))
        XCTAssertTrue(detail.contains("GPU Temperature"))
        XCTAssertTrue(network.contains("GeekPrecisionNetworkChart("))
        XCTAssertTrue(detail.contains("GeekDiskIOChart("))
        XCTAssertTrue(detail.contains("store.energyImpactSnapshot"))
        XCTAssertTrue(detail.contains("batteryElectricalSnapshot"))
        XCTAssertTrue(detail.contains("points: powerHistory"))
        XCTAssertTrue(detail.contains("metric: .batteryPower"))
        XCTAssertTrue(detail.contains("duration: geekChartDuration"))
        XCTAssertFalse(detail.contains("未采集常驻 120 秒功率历史"))
        XCTAssertTrue(detail.contains("Performance-Level Topology"))
        XCTAssertTrue(detail.contains("Read Operations"))
        XCTAssertTrue(network.contains("connection.activeInterface?.hardwareAddress"))
        XCTAssertTrue(network.contains("GeekNetworkTertiaryView"))
        XCTAssertTrue(detail.contains("TertiaryMultilineValueRow"))
        XCTAssertTrue(detail.contains("energy.calibrationText"))
        XCTAssertTrue(detail.contains("app.measurementTitle"))
        XCTAssertTrue(detail.contains("Reading capacity and native I/O counters"))
        XCTAssertFalse(detail.contains(".sheet("))
        XCTAssertFalse(detail.contains("NSWindow"))
        XCTAssertFalse(detail.contains("SMCFanSpeedService"))
        XCTAssertFalse(network.contains("publicIPAddress"))
    }

    func testCircularGaugeNormalizesUnavailableAndOutOfRangeProgress() {
        XCTAssertNil(PanelCircularGauge.normalizedProgress(nil))
        XCTAssertNil(PanelCircularGauge.normalizedProgress(.nan))
        XCTAssertNil(PanelCircularGauge.normalizedProgress(.infinity))
        XCTAssertEqual(PanelCircularGauge.normalizedProgress(-0.25), 0)
        XCTAssertEqual(PanelCircularGauge.normalizedProgress(0.42), 0.42)
        XCTAssertEqual(PanelCircularGauge.normalizedProgress(1.25), 1)
    }

    func testOnDemandCPUAndRawVMCounterLabelsStayTruthful() throws {
        let processor = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarProcessorPanel.swift")
        let memory = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarMemoryPanel.swift")
        let power = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarPowerPanel.swift")
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")

        XCTAssertTrue(processor.contains("Latest On-Demand App Measurement"))
        XCTAssertTrue(processor.contains("timestampText(measurement.generatedAt)"))
        XCTAssertTrue(processor.contains("not a live process ranking"))
        XCTAssertTrue(memory.contains("Raw VM Counters (May Overlap)"))
        XCTAssertTrue(memory.contains("These counters must not be added together."))
        XCTAssertTrue(power.contains("Current App Power"))
        XCTAssertFalse(power.contains("Measured Power"))
        XCTAssertTrue(detail.contains("Measurement Source"))
        XCTAssertFalse(detail.contains("Measured Power"))
    }

    func testMemoryTertiaryDetailKeepsPressureDirectionWithoutRepeatedExplanation() throws {
        let detail = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift"
        )

        XCTAssertTrue(detail.contains(
            "L10n.text(\"当前内存压力\", \"Current Memory Pressure\")"
        ))
        XCTAssertTrue(detail.contains("memoryPressureDisplayText"))
        XCTAssertTrue(detail.contains("memoryPressureHeadroomText"))
        XCTAssertTrue(detail.contains("压力趋势估算"))
        XCTAssertTrue(detail.contains("内存占用与压力趋势估算"))
        XCTAssertTrue(detail.contains("memory usage and pressure trend estimate"))
        XCTAssertFalse(detail.contains("Text(memoryPressureExplanation)"))
        XCTAssertTrue(detail.contains("channel: .memoryPressure"))
        XCTAssertTrue(detail.contains("占用平均 / 峰值"))
    }

    func testDiskDetailsSeparateUserAvailableStrictFreeAndReclaimableEstimate() throws {
        let sources = try [
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarDiskPanel.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift",
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift",
        ].map(source).joined(separator: "\n")

        for label in [
            "L10n.text(\"系统可用\", \"System Available\")",
            "L10n.text(\"当前严格空闲\", \"Current Strict Free\")",
            "L10n.text(\"可回收估算\", \"Reclaimable Estimate\")",
        ] {
            XCTAssertTrue(sources.contains(label), label)
        }
        for field in [
            "userAvailableBytes",
            "availableBytes",
            "reclaimableEstimateBytes",
        ] {
            XCTAssertTrue(sources.contains(field), field)
        }
        XCTAssertTrue(sources.contains("ByteFormat.storageString("))
        XCTAssertFalse(sources.contains("Available for Important Usage"))
        XCTAssertFalse(sources.contains("Available for Opportunistic Usage"))
    }

    func testTertiaryNetworkDetailsPreferThePhysicalTopologySnapshot() throws {
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let network = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")

        XCTAssertTrue(detail.contains("GeekNetworkTertiaryView("))
        XCTAssertTrue(network.contains("ScrollView(.vertical)"))
        XCTAssertTrue(network.contains("NetworkConnectionSnapshot.resolve"))
        XCTAssertTrue(network.contains("connection.wifi?.phyMode"))
        XCTAssertTrue(network.contains("let topology: NetworkTopologySnapshot?"))
        XCTAssertTrue(network.contains("connection.activeInterface?.bsdName"))
        XCTAssertTrue(network.contains("connection.ipConfiguration.ipv4Router"))
        XCTAssertTrue(network.contains("connection.ipConfiguration.ipv6Router"))
        XCTAssertTrue(network.contains("connection.ipConfiguration.dnsServers"))
        XCTAssertTrue(network.contains("GeekNetworkInspectorAddressRow"))
        XCTAssertTrue(detail.contains("topology: networkTopologySnapshot"))
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
