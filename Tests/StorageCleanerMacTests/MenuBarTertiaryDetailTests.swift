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
        XCTAssertFalse(chrome.contains("ScrollView"))
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
        let memoryPanel = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let network = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")

        XCTAssertTrue(root.contains("@State var activeTertiaryDetail: MenuBarTertiaryDetail?"))
        XCTAssertFalse(detail.contains("func tertiaryDetailButton("))
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
        XCTAssertTrue(memoryPanel.contains("guard tertiaryPresentationMode == .column else { return }"))
        XCTAssertTrue(memoryPanel.contains("if tertiaryPresentationMode == .unavailable"))
        XCTAssertTrue(root.contains("if panelSettingsState.tertiaryPresentationMode == .unavailable"))
        XCTAssertTrue(root.contains("guard panelCoordinator.presentHistory("))
        XCTAssertTrue(root.contains(".inline(request.id)"))
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
        XCTAssertTrue(memoryPanel.contains("struct GeekMemoryHistoryHoverDetail:"))
        XCTAssertTrue(detail.contains("points: memoryHistory"))
        XCTAssertTrue(detail.contains("GeekMemoryHistoryHoverDetail("))
        XCTAssertTrue(detail.contains("channel: .gpuTemperature"))
        XCTAssertTrue(detail.contains("GPU Temperature"))
        XCTAssertTrue(network.contains("GeekPrecisionNetworkChart("))
        XCTAssertTrue(detail.contains("GeekDiskIOHoverDetail("))
        XCTAssertFalse(detail.contains("store.energyImpactSnapshot"))
        XCTAssertTrue(detail.contains("batteryElectricalSnapshot"))
        XCTAssertTrue(detail.contains("points: powerHistory"))
        XCTAssertTrue(detail.contains("metric: .batteryPower"))
        XCTAssertTrue(detail.contains("duration: geekChartDuration"))
        XCTAssertFalse(detail.contains("未采集常驻 120 秒功率历史"))
        XCTAssertFalse(detail.contains("Performance-Level Topology"))
        XCTAssertFalse(detail.contains("Read Operations"))
        XCTAssertTrue(network.contains("connection.activeInterface?.hardwareAddress"))
        XCTAssertTrue(network.contains("GeekNetworkTertiaryView"))
        XCTAssertTrue(detail.contains("TertiaryMultilineValueRow"))
        XCTAssertFalse(detail.contains("energy.calibrationText"))
        XCTAssertFalse(detail.contains("app.measurementTitle"))
        XCTAssertFalse(detail.contains("Reading capacity and native I/O counters"))
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
        // D64 drops dormant copy; retain the measurement provenance contract
        // on the actual live CPU rows and memory detail sources.
        let processor = try D64MenuBarSource.source("MenuBarAdvanced/GeekProcessorView.swift")
        XCTAssertTrue(processor.contains("最近一次按需 CPU 测量"))
        XCTAssertTrue(processor.contains("Latest on-demand CPU measurement"))
        XCTAssertTrue(processor.contains("store.menuBarPreparedProcesses?.cpu"))
        let memory = try D64MenuBarSource.source("MenuBarAdvanced/GeekMemoryView.swift")
        XCTAssertTrue(memory.contains("row.help"))
        XCTAssertTrue(memory.contains(".help(row.help)"))
        XCTAssertTrue(memory.contains(".accessibilityHint(row.help)"))
        let rows = try r2SourceDeclaration("enum GeekMemorySwapActivity", in: memory)
        XCTAssertTrue(rows.contains("换入（累计）"))
        XCTAssertTrue(rows.contains("Swapped In (Total)"))
        XCTAssertTrue(rows.contains("Compressed data read back from the swap files since startup."))
        XCTAssertTrue(rows.contains("Compressed data written to the swap files since startup."))
        let composition = try String(contentsOf: D64MenuBarSource.root.appendingPathComponent(
            "Sources/StorageCleanerMac/Models/SystemModels.swift"), encoding: .utf8)
        let normalized = try r2SourceDeclaration("struct MemoryRingComposition:", in: composition)
        XCTAssertTrue(normalized.contains("let wiredBytes = min(rawWiredBytes, usedBytes)"))
        XCTAssertTrue(normalized.contains("let compressedBytes = min(rawCompressedBytes, usedBytes - wiredBytes)"))
        let power = try D64MenuBarSource.source("MenuBarAdvanced/MenuBarGeekPanel.swift")
        XCTAssertTrue(power.contains("snapshot?.currentPowerWattsText"))
        let detail = try D64MenuBarSource.source("MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        XCTAssertFalse(detail.contains("Measurement Source"))
        XCTAssertFalse(detail.contains("Measured Power"))
    }

    func testMemoryTertiaryDetailReusesCompositionWithoutExtraStatistics() throws {
        let sourceText = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let detail = try XCTUnwrap(sourceText.components(separatedBy: "private var tertiaryMemoryDetail: some View {").last?.components(separatedBy: "private var tertiaryDiskDetail").first)
        XCTAssertTrue(detail.contains("GeekMemoryHistoryHoverDetail("))
        XCTAssertTrue(detail.contains("points: memoryHistory"))
        XCTAssertTrue(detail.contains("snapshot: memorySnapshot"))
        XCTAssertFalse(detail.contains("channel: .memoryPressure"))
        XCTAssertFalse(detail.contains("channel: .swapUsedBytes"))
        XCTAssertFalse(detail.contains("占用平均 / 峰值"))
    }

    func testDiskDetailsSeparateUserAvailableStrictFreeAndReclaimableEstimate() throws {
        let sources = try [
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift",
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
        // D128 (2026-10-19): iStat's disk space format (was `ByteFormat.storageString(`).
        XCTAssertTrue(sources.contains("IStatNumberFormat.space("))
        XCTAssertFalse(sources.contains("Available for Important Usage"))
        XCTAssertFalse(sources.contains("Available for Opportunistic Usage"))
    }

    func testTertiaryNetworkDetailsPreferThePhysicalTopologySnapshot() throws {
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let network = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")

        XCTAssertTrue(detail.contains("GeekNetworkTertiaryView("))
        XCTAssertFalse(network.contains("ScrollView"))
        XCTAssertTrue(network.contains("NetworkConnectionSnapshot.resolve"))
        // D125 (2026-10-19): the Wi-Fi rows read the resolved connection's
        // Wi-Fi details (was `connection.wifi?.phyMode` in a fixed card).
        XCTAssertTrue(network.contains("if let wifi = connection.wifi"))
        XCTAssertTrue(network.contains("wifi.phyMode"))
        XCTAssertTrue(network.contains("let topology: NetworkTopologySnapshot?"))
        XCTAssertTrue(network.contains("connection.activeInterface?.bsdName"))
        XCTAssertTrue(network.contains("connection.ipConfiguration.ipv4Router"))
        XCTAssertTrue(network.contains("connection.ipConfiguration.ipv6Router"))
        XCTAssertTrue(network.contains("connection.ipConfiguration.dnsServers"))
        // D125 (2026-10-19): iStat's interface sections (were
        // `GeekNetworkInspectorAddressRow` rows in fixed cards).
        XCTAssertTrue(network.contains("GeekIStatInterfaceSections("))
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
