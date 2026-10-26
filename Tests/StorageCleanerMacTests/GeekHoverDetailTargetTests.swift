import CoreGraphics
import XCTest
@testable import StorageCleanerMac

final class GeekHoverDetailTargetTests: XCTestCase {
    func testHoverTimingKeepsAStableBridgeIntoTheAttachedThirdColumn() {
        XCTAssertEqual(HoverIntentPolicy.menuBar.initialOpenDelay, .zero)
        XCTAssertEqual(HoverIntentPolicy.menuBar.switchDelay, .zero)
        // D123 (2026-10-19): a submenu the pointer leaves without entering
        // closes at once, as in iStat Menus 7.30 (was 260 ms); the control
        // palettes keep 260 ms.
        XCTAssertEqual(HoverIntentPolicy.menuBar.ordinaryCloseDelay, .zero)
        XCTAssertEqual(HoverIntentPolicy.controlPalette.ordinaryCloseDelay, .milliseconds(260))
        XCTAssertEqual(HoverIntentPolicy.menuBar.corridorGraceDuration, .milliseconds(320))
        // D123 (2026-10-19): the hold has no time limit. iStat Menus 7.30's
        // 1 s check holds again at once while the pointer still heads for the
        // child (was `corridorMaximumHold`, 1 s, D117).
        XCTAssertFalse(
            Mirror(reflecting: HoverIntentPolicy.menuBar).children.contains { $0.label == "corridorMaximumHold" }
        )
        // D123 (2026-10-19): a one-point step toward the child's side starts
        // the hold, and it lasts while every step keeps going that way;
        // stopping does not end it, any other step does (was a 50 ms progress
        // check, `corridorRecheckInterval`).
        XCTAssertEqual(HoverIntentPolicy.menuBar.headingStep, 1)
    }

    @MainActor
    func testReferenceTertiaryDetailGeometryIsKeptExplicit() {
        XCTAssertEqual(GeekHoverDetailMetrics.historySize, CGSize(width: MiniWindowStyleTokens.historyWidth, height: 216))
        XCTAssertEqual(GeekHoverDetailMetrics.cpuHistorySize, GeekHoverDetailMetrics.historySize)
        // D121 (2026-10-18): a history page is the graph card and its rows
        // below it: memory pressure one row, disk I/O two (both were the
        // bare 216 pt history size).
        XCTAssertEqual(GeekHoverDetailMetrics.memoryHistorySize, GeekIStatHistoryGeometry.pageSize(rowCount: 1))
        XCTAssertEqual(GeekHoverDetailMetrics.diskIOSize, GeekIStatHistoryGeometry.pageSize(rowCount: 2))
        // D132 (2026-10-19): iStat's battery history submenu is 319 wide with
        // a 180 pt graph; was `GeekHoverDetailMetrics.historySize` (391 × 216).
        XCTAssertEqual(GeekSensorPowerHoverDetailMetrics.batteryHistorySize, CGSize(width: 319, height: 196))
        XCTAssertGreaterThan(GeekMemoryCompositionHistoryDetail.preferredSize.height, GeekHoverDetailMetrics.historySize.height)
        for size in [GeekHoverDetailMetrics.cpuHistorySize, GeekHoverDetailMetrics.memoryHistorySize, GeekHoverDetailMetrics.cpuUsageSize] {
            XCTAssertEqual(GeekPanelPresentationMetrics.normalizedTertiarySize(size), size)
        }
        XCTAssertEqual(GeekHoverDetailMetrics.compactHistorySize, CGSize(width: MiniWindowStyleTokens.compactHistoryWidth, height: 216))
        // D122 (2026-10-18): the volume page is the 200 pt space card and its
        // reading rows, sized by them (was the fixed `volumeSize`, 220 × 339);
        // a network volume before its capacity is read is its two rows.
        XCTAssertEqual(GeekDiskVolumeHoverDetail.popoverSize(rowCount: 4), CGSize(width: 220, height: 299))
        XCTAssertEqual(GeekDiskVolumeHoverDetail.popoverSize(rowCount: 2), CGSize(width: 220, height: 265))
        XCTAssertEqual(GeekDiskVolumeHoverDetail.networkWithoutCapacitySize, CGSize(width: 220, height: 58))
        // D137 (2026-10-19): the VPN page is its widest section + 20, 220 at
        // the least (was the fixed `GeekHoverDetailMetrics.vpnWidth`, 220).
        XCTAssertEqual(GeekIStatContentWidth.page(sections: [GeekIStatContentWidth.sectionMinimum]), 220)
        // D122 (2026-10-18): one card of three title-and-value groups, iStat's
        // uptime menu (was 106 for two rows). D137 (2026-10-19): its section +
        // 20, from 150 (was `GeekHoverDetailMetrics.uptimeSize`, 220 × 130).
        XCTAssertEqual(GeekProcessorUptimeHoverDetail(poweredOnAt: "—", awake: "—", asleep: "—").popoverSize,
                       CGSize(width: 170, height: 130))
        // D122 (2026-10-18): the usage page is a history page with its rows
        // below the graph card (were 270 and 293).
        XCTAssertEqual(GeekHoverDetailMetrics.cpuUsageSize, GeekIStatHistoryGeometry.pageSize(rowCount: 3))
        XCTAssertEqual(GeekHoverDetailMetrics.cpuLoadSize, GeekIStatHistoryGeometry.pageSize(rowCount: 4))
        // D125 (2026-10-19): the connection page is iStat's interface submenu,
        // sized by its sections (was the fixed `referenceSize`, 255 × 419).
        // D137 (2026-10-19): its width too, the widest section + 20 (was
        // `GeekNetworkTertiaryView.pageWidth`, 255).
        #if DEBUG || STORAGE_CLEANER_BETA
        // The demo Wi-Fi connection: interface 61, Wi-Fi 163, addresses 57,
        // IPv4 78, IPv6 61.
        let demoConnection = NetworkConnectionSnapshot.resolve(
            native: MiniWindowDemoData.networkInterfaceSnapshot,
            topology: nil
        )
        XCTAssertEqual(
            GeekNetworkTertiaryView.preferredSize(for: demoConnection),
            CGSize(width: GeekIStatInterfaceModel(connection: demoConnection).pageWidth(), height: 464)
        )
        #endif
    }

    func testHoverTargetRequestsTheRootHostedThirdColumnWithoutCreatingWindowInfrastructure() throws {
        let source = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")

        XCTAssertFalse(source.contains(".popover("))
        XCTAssertFalse(source.contains("Task.sleep(for:"))
        XCTAssertFalse(source.contains("hoverGeneration"))
        XCTAssertTrue(source.contains("hoverCoordinator.scheduleTertiaryPreview("))
        XCTAssertTrue(source.contains("hoverCoordinator.scheduleHoverDismissal("))
        XCTAssertTrue(source.contains("onContinuousHover"))
        XCTAssertTrue(source.contains("isTargetHovered"))
        XCTAssertTrue(source.contains("isDetailHovered"))
        XCTAssertTrue(source.contains("@Environment(\\.geekPanelHoverActivity)"))
        XCTAssertTrue(source.contains("@Environment(\\.menuBarTertiaryPresentationMode)"))
        XCTAssertTrue(source.contains("@Environment(\\.geekInlineTertiaryEvent)"))
        XCTAssertTrue(source.contains("@Environment(\\.geekInlineTertiaryActiveRequestID)"))
        XCTAssertTrue(source.contains("panelActivityID"))
        XCTAssertTrue(source.contains("isInlinePresented || isTargetHovered || isDetailHovered"))
        XCTAssertTrue(source.contains("guard tertiaryPresentationMode == .column else { return }"))
        XCTAssertTrue(source.contains("tertiaryPresentationMode == .unavailable"))
        XCTAssertTrue(source.contains("inlineTertiaryEvent?(.present"))
        XCTAssertTrue(source.contains("inlineTertiaryEvent?(.dismiss(panelActivityID))"))
        XCTAssertTrue(source.contains("preferredSize: popoverSize"))
        XCTAssertTrue(source.contains("sourceOffset: measuredSourceOffset ?? sourceOffset"))
        XCTAssertTrue(source.contains("GeekTertiarySourceOffsetKey.self"))
        XCTAssertTrue(source.contains("GeekTertiarySourceCoordinateSpace.name"))
        XCTAssertTrue(source.contains("hoverChanged: detailHoverChanged"))
        XCTAssertTrue(source.contains("store.content.id(store.identity)"))
        XCTAssertTrue(source.contains("panelHoverActivity?(panelActivityID, active)"))
        XCTAssertTrue(source.contains("accessibilityAction"))
        XCTAssertFalse(source.contains("NSPanel"))
        XCTAssertFalse(source.contains("NSWindow("))
        XCTAssertFalse(source.contains("Timer("))
        XCTAssertFalse(source.contains("DispatchSource"))
    }

    func testTertiaryDismissalHonorsTheFullCascadeHoverEnvelope() throws {
        let target = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let tertiary = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let advanced = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")

        XCTAssertTrue(target.contains("@Environment(\\.geekPanelHoverEnvelopeActive)"))
        XCTAssertTrue(target.contains(".onChange(of: isPanelHoverEnvelopeActive)"))
        // D123 (2026-10-19): leaving a row for a gap in the module column
        // closes its page inside the envelope too, as a change of target does
        // in iStat Menus 7.30 (was `&& !isPanelHoverEnvelopeActive`).
        let dismissal = try r2SourceDeclaration("private func scheduleDismissal(", in: target)
        XCTAssertTrue(dismissal.contains("&& hoverCoordinator.allowsTertiaryGapClose"))
        XCTAssertFalse(dismissal.contains("!isPanelHoverEnvelopeActive"))
        XCTAssertTrue(tertiary.contains("!panelCoordinator.isPointerWithinHoverEnvelope"))
        XCTAssertTrue(tertiary.contains("panelCoordinator.dismissUnpinnedHierarchy()"))
        XCTAssertTrue(advanced.contains("panelCoordinator.scheduleHoverDismissal("))
        XCTAssertTrue(advanced.contains("scheduleTertiaryDetailDismissal(detail)"))
        XCTAssertTrue(advanced.contains("geekPanelHoverActivityState.reset()"))
        // D123 (2026-10-19): a row's page closes alone; the module column
        // follows its own rules (was `dismissUnpinnedHierarchy()`).
        let inlineEvent = try r2SourceDeclaration("private func handleInlineTertiaryEvent(", in: advanced)
        XCTAssertTrue(inlineEvent.contains("panelCoordinator.dismissHistory()"))
        XCTAssertFalse(inlineEvent.contains("dismissUnpinnedHierarchy"))
    }

    func testSnapshotCaptureBlocksPointerHoverAtBothTertiaryEntryPoints() throws {
        let target = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let tertiary = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let session = try source("Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift")
        let advanced = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")

        let hover = try r2SourceDeclaration("private func targetHoverChanged(", in: target)
        let captureGuard = try XCTUnwrap(hover.range(of:
            "guard !MiniWindowDemoData.isCapturingMenuBarPanelSnapshots else { return }"
        ))
        // D64 retired the other pointer opener (the legacy detail button).
        // The live target must reject capture-time hover before changing state
        // or taking either the immediate or coordinated preview path.
        XCTAssertTrue(hover.contains("#if DEBUG || STORAGE_CLEANER_BETA"))
        for effect in ["isTargetHovered = hovering", "presentDetail(pinned: false)", "scheduleTertiaryPreview("] {
            let effectRange = try XCTUnwrap(hover.range(of: effect))
            XCTAssertLessThan(captureGuard.lowerBound, effectRange.lowerBound, effect)
        }
        XCTAssertTrue(target.contains("targetHoverChanged(true)"))
        XCTAssertTrue(target.contains("targetHoverChanged(false)"))
        XCTAssertFalse(tertiary.contains("func tertiaryDetailButton("))
        XCTAssertFalse(tertiary.contains("func tertiaryButtonHoverChanged("))
        XCTAssertTrue(session.contains("panelCoordinator?.presentHistory("))
        XCTAssertTrue(session.contains("requestedSection?.tertiaryDetail?.rawValue"))
        XCTAssertTrue(session.contains("?? \"debug.processor.activity\""))
        XCTAssertTrue(advanced.contains("let range = panelSettingsState.geekChartRange("))
        XCTAssertTrue(advanced.contains("let points = telemetryHistory(for: range)"))
        XCTAssertTrue(advanced.contains("userValue: percentText(points.last?.cpuUser)"))
        XCTAssertTrue(advanced.contains("samplingInterval: store.menuBarRefreshInterval.seconds"))
        XCTAssertTrue(advanced.contains("duration: range.duration"))
        XCTAssertTrue(advanced.contains("MenuBarObservedObjectBoundary(model: monitorState)"))
    }

    func testAttachedColumnKeepsItsRootHostedDetailLiveWhileTheSourceStaysMounted() throws {
        let targetSource = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let host = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let disappearStart = try XCTUnwrap(targetSource.range(of: ".onDisappear {")?.lowerBound)
        let onChangeStart = try XCTUnwrap(
            targetSource.range(
                of: ".onChange(of: tertiaryPresentationMode)",
                range: disappearStart..<targetSource.endIndex
            )?.lowerBound
        )
        let disappearBlock = String(targetSource[disappearStart..<onChangeStart])

        XCTAssertTrue(disappearBlock.contains("reportPanelActivity(false)"))
        XCTAssertTrue(disappearBlock.contains("dismissDetail()"))
        XCTAssertTrue(targetSource.contains("contentStore: inlineContentStore"))
        XCTAssertTrue(targetSource.contains("GeekInlineTertiaryContentReporter("))
        XCTAssertTrue(targetSource.contains("store.update(content, now: now)"))
        XCTAssertTrue(targetSource.contains("GeekInlineTertiaryContentRefreshPolicy"))
        XCTAssertTrue(targetSource.contains("@State private var inlineContentStore"))
        XCTAssertFalse(targetSource.contains("@StateObject private var inlineContentStore"))
        XCTAssertTrue(targetSource.contains("activeInlineRequestID != panelActivityID"))
        XCTAssertGreaterThanOrEqual(
            targetSource.components(separatedBy: "isDetailHovered = false").count - 1,
            2
        )
        XCTAssertTrue(targetSource.contains("isInlinePresented = false"))
        XCTAssertTrue(host.contains("func tertiaryDetailRootHost<Content: View>"))
        XCTAssertTrue(host.contains("content()"))
        XCTAssertTrue(host.contains("GeekInlineTertiaryLiveContent(store: request.contentStore)"))
        XCTAssertTrue(host.contains(".onContinuousHover"))
        XCTAssertTrue(host.contains("request.hoverChanged(true)"))
        XCTAssertTrue(host.contains("request.hoverChanged(false)"))
        XCTAssertFalse(host.contains("showsReplacementTertiarySurface"))
        XCTAssertFalse(host.contains(".popover("))
    }

    func testInlineContentRefreshPolicySuppressesTimelineOnlyRebuilds() {
        let start = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(
            GeekInlineTertiaryContentRefreshPolicy.shouldPublish(
                lastPublishedAt: nil,
                now: start
            )
        )
        XCTAssertFalse(
            GeekInlineTertiaryContentRefreshPolicy.shouldPublish(
                lastPublishedAt: start,
                now: start.addingTimeInterval(0.015)
            )
        )
        XCTAssertTrue(
            GeekInlineTertiaryContentRefreshPolicy.shouldPublish(
                lastPublishedAt: start,
                now: start.addingTimeInterval(0.017)
            )
        )
        XCTAssertTrue(
            GeekInlineTertiaryContentRefreshPolicy.shouldPublish(
                lastPublishedAt: start,
                now: start,
                force: true
            )
        )
    }

    @MainActor
    func testTertiaryRequestForwardsWholeColumnHoverActivity() {
        let recorder = TertiaryHoverRecorder()
        let request = GeekInlineTertiaryRequest(
            id: UUID(),
            accessibilityLabel: "Tertiary",
            preferredSize: CGSize(width: 170, height: 167),
            sourceOffset: 198,
            contentStore: GeekInlineTertiaryContentStore(),
            hoverChanged: { recorder.record($0) }
        )

        request.hoverChanged(true)
        request.hoverChanged(false)

        XCTAssertEqual(recorder.states, [true, false])
        XCTAssertEqual(request.preferredSize, CGSize(width: 170, height: 167))
        XCTAssertEqual(request.sourceOffset, 198)
    }

    func testProcessorMemoryAndDiskCardsExposeContextualHoverDetails() throws {
        let processor = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift")
        let memory = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        let disk = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift")
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")

        XCTAssertEqual(processor.components(separatedBy: "GeekHoverDetailTarget(").count - 1, 4)
        XCTAssertEqual(memory.components(separatedBy: "GeekHoverDetailTarget(").count - 1, 3)
        // One volume target, one combined chart target, and one reusable
        // target instantiated for each of the read/write values.
        XCTAssertEqual(disk.components(separatedBy: "GeekHoverDetailTarget(").count - 1, 3)

        XCTAssertTrue(processor.contains("GeekProcessorActivityHoverDetail"))
        XCTAssertTrue(processor.contains("GeekGPUHoverDetail"))
        XCTAssertTrue(processor.contains("GeekProcessorUsageHoverDetail"))
        XCTAssertTrue(processor.contains("GeekProcessorUptimeHoverDetail"))
        XCTAssertTrue(memory.contains("GeekMemoryHistoryHoverDetail"))
        XCTAssertTrue(memory.contains("GeekMemoryCompositionHistoryDetail"))
        XCTAssertFalse(memory.contains("pressureExplanation:"))
        XCTAssertFalse(memory.contains("GeekMemoryCompositionHoverDetail"))
        XCTAssertTrue(memory.contains("GeekSwapHoverDetail"))
        XCTAssertTrue(disk.contains("GeekDiskVolumeHoverDetail"))
        XCTAssertTrue(disk.contains("GeekDiskIOHoverDetail"))
        XCTAssertTrue(disk.contains("geekDiskThroughputHoverTarget(.read)"))
        XCTAssertTrue(disk.contains("geekDiskThroughputHoverTarget(.write)"))
        XCTAssertTrue(disk.contains("GeekDiskThroughputHoverDetail"))

        XCTAssertFalse(detail.contains("L10n.text(\"历史趋势\", \"History Trend\")"))
        // Batch 2b review: the GPU memory reading keeps one name
        // (GeekGPUVocabulary) on the CPU page ring and here; D138: iStat's
        // 内存 / Memory (was 显存 / GPU Memory).
        XCTAssertTrue(detail.contains("title: GeekGPUVocabulary.memory"))
        XCTAssertFalse(detail.contains("频率 / FPS"))
        XCTAssertFalse(detail.contains("value: \"-- / --\""))
        XCTAssertFalse(detail.contains("Text(pressureExplanation)"))
    }

    func testDiskWriteChartUsesItsOwnScaleInsteadOfReadPeak() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let points = (0..<3).map { index in
            NativeDiskIOPoint(
                date: now.addingTimeInterval(Double(index - 2)),
                readBytesPerSecond: 10_000,
                writeBytesPerSecond: 100,
                readOperationsPerSecond: 2,
                writeOperationsPerSecond: 1
            )
        }
        let frame = GeekPreparedDiskFrame(
            points: points,
            plot: CGRect(x: 0, y: 0, width: 240, height: 100),
            duration: 120,
            reference: now,
            scale: 2
        )

        XCTAssertEqual(frame.writeMaximum, GeekBarChartScale.throughputFloor)
        // D120 (2026-10-18): the visible peak itself; D117's tier was 12 500.
        XCTAssertEqual(frame.readMaximum, 10_000)
        // D117: the combined chart's write half also uses the write scale
        // instead of sharing the read peak.
        let charts = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift")
        let diskChart = try XCTUnwrap(charts.components(separatedBy: "struct GeekDiskIOChart: View {").last)
        // D121 (2026-10-18): a history recomputes the scale without easing
        // (`easesScale: false`); either way each half keeps its own target.
        // Were `maximum: writeAxisScale.displayedMaximum(fallback: writeTarget)`.
        // D130/D131 (2026-10-19): `eases` also needs the projection (were
        // `maximum: easesScale ? …`).
        XCTAssertTrue(diskChart.contains(
            "maximum: eases ? writeAxisScale.displayedMaximum(fallback: writeTarget) : writeTarget"))
        XCTAssertTrue(diskChart.contains(
            "maximum: eases ? readAxisScale.displayedMaximum(fallback: readTarget) : readTarget"))
    }

    func testSwapDetailKeepsMeasuredZeroUnknownAndHistoricalPeakDistinct() {
        let unknown = GeekSwapDetailData(usedBytes: nil, totalBytes: nil)
        XCTAssertEqual(unknown.summary, "—")
        XCTAssertNil(unknown.fraction)

        let onDemand = GeekSwapDetailData(usedBytes: 0, totalBytes: 0)
        XCTAssertNil(onDemand.fraction)
        XCTAssertTrue(onDemand.summary.contains("按需分配") || onDemand.summary.contains("On Demand"))

        let mebibyte: UInt64 = 1_048_576
        let measured = GeekSwapDetailData(usedBytes: 2 * mebibyte, totalBytes: 4 * mebibyte)
        XCTAssertEqual(measured.fraction, 0.5)
        XCTAssertTrue(measured.summary.contains(" / "))
        XCTAssertEqual(
            GeekSwapDetailData(usedBytes: 5 * mebibyte, totalBytes: 4 * mebibyte).fraction,
            1
        )

        let point = MenuBarTelemetryPoint(
            date: Date(timeIntervalSince1970: 100), cpuTotal: nil, cpuUser: nil,
            cpuSystem: nil, gpu: nil, memory: nil, swapUsedBytes: 9 * mebibyte,
            chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil,
            upBytesPerSecond: nil
        )
        XCTAssertEqual(measured.chartMaximum(for: [point]), Double(9 * mebibyte))
        XCTAssertEqual(onDemand.chartMaximum(for: []), 1)
    }

    func testSwapHistoryUsesTheExistingMemoryRangeAndRealSamples() throws {
        let memory = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let swapTarget = try XCTUnwrap(memory.components(separatedBy: "private var geekMemorySwapHoverTarget").last?.components(separatedBy: "private var geekSwapProgress").first)
        let swapDetail = try XCTUnwrap(detail.components(separatedBy: "struct GeekSwapHoverDetail: View {").last?.components(separatedBy: "struct GeekDiskVolumeHoverDetail").first)
        XCTAssertTrue(swapTarget.contains("chartRangeMetric: .memory"))
        XCTAssertTrue(swapTarget.contains("points: memoryHistory"))
        XCTAssertTrue(swapTarget.contains("duration: geekMetricRange(.memory).duration"))
        // D133: iStat's swap history draws the swap files' used share (was
        // `channel: .swapUsedBytes`).
        XCTAssertTrue(swapDetail.contains("channel: .swapUsedPercent"))
        XCTAssertTrue(swapDetail.contains("showsRangePicker: true"))
        XCTAssertFalse(swapDetail.contains("GeekHoverLargeValue"))
    }

    func testNetworkTrendConnectionAndVPNUseSharedAttachedHoverDetail() throws {
        let network = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")

        XCTAssertEqual(network.components(separatedBy: "GeekHoverDetailTarget(").count - 1, 3)
        // D121 (2026-10-18): the page's own size, the card and its two rows
        // (was `GeekHoverDetailMetrics.compactHistorySize`).
        XCTAssertTrue(network.contains("GeekNetworkHistoryHoverDetail.popoverSize"))
        XCTAssertTrue(network.contains("GeekNetworkHistoryHoverDetail("))
        // D140 (2026-10-19): the IP section's reading state (was `isLoading:`
        // of the address card).
        XCTAssertTrue(network.contains(
            "let isReading = !store.isMenuBarRefreshPaused && networkTopologySnapshot == nil && networkInterfaceSnapshot == nil"
        ))
        // D125 (2026-10-19): the page's size from its sections.
        XCTAssertTrue(network.contains("popoverSize: GeekNetworkTertiaryView.preferredSize(for: geekConnectionSnapshot)"))
        XCTAssertTrue(network.contains("GeekNetworkTertiaryView("))
        XCTAssertTrue(network.contains("snapshot: networkInterfaceSnapshot"))
        XCTAssertTrue(network.contains("topology: networkTopologySnapshot"))
        XCTAssertTrue(network.contains("refresh: refreshPanelData"))
        XCTAssertTrue(network.contains("network.connection.inspector"))
        XCTAssertFalse(network.contains("ControlPaletteHoverAnchor("))
        XCTAssertTrue(network.contains("GeekVPNDisclosure"))
        XCTAssertTrue(network.contains("GeekVPNHoverDetail.preferredSize(for: tunnel)"))
        // D137 (2026-10-19): the VPN page's width from its sections and button
        // (was `width: GeekHoverDetailMetrics.vpnWidth`). D140: the sections
        // measured at that width, where an address wraps (was `width:
        // model.pageWidth(buttonTitles: reservesButton ? actionTitles : [])`
        // in the size).
        XCTAssertTrue(network.contains("let width = model.pageWidth(buttonTitles: reservesButton ? actionTitles : [])"))
        XCTAssertTrue(network.contains("var cards = model.sectionHeights(pageWidth: width)"))
        XCTAssertFalse(network.contains("width: GeekHoverDetailMetrics.vpnWidth"))
        XCTAssertTrue(network.contains("sourceOffset: 158"))
        XCTAssertFalse(network.contains("GeekNetworkInterfaceDisclosure"))
        XCTAssertTrue(detail.contains("struct GeekNetworkHistoryHoverDetail"))
        XCTAssertTrue(detail.contains("GeekPrecisionNetworkChart("))
        XCTAssertFalse(network.contains("@State private var isShowingDetail"))
        XCTAssertFalse(network.contains("hoverTask"))
    }

    func testLiveNetworkAndBatteryDetailsAdoptMeasuredContentHeight() throws {
        let advanced = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let sensorPower = try source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift"
        )
        let network = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")
        let power = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift")

        XCTAssertTrue(advanced.contains("if let request = activeInlineTertiaryRequest"))
        XCTAssertTrue(advanced.contains("measurement.requestID == request.id"))
        XCTAssertTrue(advanced.contains("width: request.preferredSize.width"))
        XCTAssertTrue(advanced.contains("height: measurement.size.height"))
        XCTAssertTrue(advanced.contains("let matchesCurrentDetail = requestID == nil"))
        XCTAssertTrue(advanced.contains("let matchesCurrentRequest ="))
        XCTAssertTrue(advanced.contains("activeInlineTertiaryRequest?.id == requestID"))
        XCTAssertTrue(advanced.contains("matchesCurrentDetail || matchesCurrentRequest"))
        XCTAssertTrue(detail.contains(".padding(pageProvidesInset ? 0 : GeekPanelLayout.contentPadding)"))
        XCTAssertFalse(detail.contains(
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"
        ))
        let batteryBody = try XCTUnwrap(
            sensorPower.components(separatedBy: "struct GeekBatteryElectricalHoverDetail").last?
                .components(separatedBy: "private var batteryRows").first
        )
        XCTAssertFalse(batteryBody.contains("maxHeight: .infinity"))
        // D121 (2026-10-18): was `popoverSize: GeekHoverDetailMetrics.compactHistorySize`.
        XCTAssertTrue(network.contains("popoverSize: GeekNetworkHistoryHoverDetail.popoverSize"))
        // D137 (2026-10-19): the battery page's size carries its content width
        // (was `popoverSize: GeekSensorPowerHoverDetailMetrics.batterySize`).
        XCTAssertTrue(power.contains("popoverSize: geekBatteryElectricalDetail.popoverSize"))
        XCTAssertTrue(sensorPower.contains("GeekSensorPowerHoverDetailMetrics.batterySize(\n            sectionRowCounts: sectionRowCounts,"))
    }

    func testEveryHoverDetailUsesItsMeasuredOwningRowTop() throws {
        let target = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let detailHost = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")

        XCTAssertTrue(target.contains("proxy.frame(in: .named(GeekTertiarySourceCoordinateSpace.name)).minY"))
        let measurementStart = try XCTUnwrap(target.range(
            of: "private func sourceOffsetChanged(_ offset: CGFloat) {"
        )?.upperBound)
        let publicationStart = try XCTUnwrap(target.range(
            of: "private func scheduleSourceOffsetUpdate()",
            range: measurementStart..<target.endIndex
        )?.lowerBound)
        let measurement = String(target[measurementStart..<publicationStart])
        XCTAssertTrue(measurement.contains("guard offset.isFinite else { return }"))
        XCTAssertTrue(measurement.contains("let normalized = max(0, offset)"))
        XCTAssertTrue(measurement.contains("guard measuredSourceOffset != normalized else { return }"))
        XCTAssertTrue(measurement.contains("measuredSourceOffset = normalized"))
        XCTAssertTrue(measurement.contains("scheduleSourceOffsetUpdate()"))

        let publicationEnd = try XCTUnwrap(target.range(
            of: "private func cancelSourceOffsetUpdate()",
            range: publicationStart..<target.endIndex
        )?.lowerBound)
        let publication = String(target[publicationStart..<publicationEnd])
        XCTAssertTrue(publication.contains("sourceOffsetUpdateTask?.cancel()"))
        XCTAssertTrue(publication.contains("Task { @MainActor in"))
        XCTAssertTrue(publication.contains("guard !Task.isCancelled"))
        XCTAssertTrue(publication.contains("activeInlineRequestID == panelActivityID"))
        XCTAssertTrue(publication.contains("let latestOffset = measuredSourceOffset"))
        XCTAssertTrue(publication.contains("inlineTertiaryEvent?(.updateSourceOffset("))
        XCTAssertTrue(publication.contains("id: panelActivityID"))
        XCTAssertTrue(publication.contains("offset: latestOffset"))
        XCTAssertTrue(detailHost.contains(".coordinateSpace(name: GeekTertiarySourceCoordinateSpace.name)"))
    }

    func testOnDemandSnapshotFreshnessHasExplicitCurrentAndStaleStates() {
        // r2-mini-sampling (D71④): subprocess-backed process lists refresh
        // every 10 s on the visible tertiary page (was 2 s).
        XCTAssertEqual(GeekOnDemandSnapshotFreshness.refreshInterval, 10)
        XCTAssertEqual(GeekOnDemandSnapshotFreshness.refreshInterval, MenuBarPerformancePolicy.visibleProcessInterval)
        let sampleStart = Date(timeIntervalSince1970: 5_000)
        XCTAssertFalse(GeekOnDemandSnapshotFreshness.shouldRefresh(startedAt: sampleStart, now: sampleStart.addingTimeInterval(9.8)))
        XCTAssertTrue(GeekOnDemandSnapshotFreshness.shouldRefresh(startedAt: sampleStart, now: sampleStart.addingTimeInterval(10)))
        XCTAssertTrue(GeekOnDemandSnapshotFreshness.shouldRefresh(startedAt: nil, now: sampleStart))
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            GeekOnDemandSnapshotFreshness.state(generatedAt: nil, now: now),
            .notMeasured
        )
        XCTAssertEqual(
            GeekOnDemandSnapshotFreshness.state(
                generatedAt: now.addingTimeInterval(-(GeekOnDemandSnapshotFreshness.staleAfter - 1)),
                now: now
            ),
            .current
        )
        XCTAssertEqual(
            GeekOnDemandSnapshotFreshness.state(
                generatedAt: now.addingTimeInterval(-GeekOnDemandSnapshotFreshness.staleAfter),
                now: now
            ),
            .stale
        )
    }

    func testProcessCardsLabelOnDemandSnapshotAndUptimeUsesMonthDayAndExactTime() throws {
        let processor = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift")
        let disk = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift")
        let timestamp = try source("Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift")

        for source in [processor, disk] {
            XCTAssertTrue(source.contains("L10n.text(\"进程\", \"PROCESSES\")"))
            XCTAssertTrue(source.contains("按需快照 · \\(geekOnDemandSnapshotStatusText)"))
            XCTAssertTrue(source.contains("geekOnDemandSnapshotStatusText"))
        }
        XCTAssertTrue(processor.contains("PanelTimestampFormat.monthDayAndTime"))
        XCTAssertTrue(timestamp.contains("dateFormat = \"M月d日 HH:mm:ss\""))
        XCTAssertTrue(timestamp.contains("dateFormat = \"MMM d HH:mm:ss\""))
        XCTAssertFalse(timestamp.contains("dateStyle = .medium"))
    }

    func testPoweredOnTimestampOmitsYearAndKeepsMonthDayAndExactTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 2,
            hour: 3,
            minute: 4,
            second: 5
        )))

        let text = PanelTimestampFormat.monthDayAndTime(date)

        XCTAssertFalse(text.contains("2026"))
        XCTAssertTrue(text == "1月2日 03:04:05" || text == "Jan 2 03:04:05", text)
    }

    func testProcessorReplacesRawLoadAverageWithReadableCPUUsage() throws {
        let processor = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift")
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")

        for source in [processor, detail] {
            // D138: iStat's LOAD row is 平均负载量 ('CPU.Load'); no other
            // raw load-average text (was `XCTAssertFalse(source.contains("平均负载"))`).
            XCTAssertEqual(source.components(separatedBy: "平均负载").count,
                           source.components(separatedBy: "L10n.text(\"平均负载量\", \"LOAD\")").count)
            XCTAssertFalse(source.contains("Load Average"))
        }
        XCTAssertTrue(processor.contains("L10n.text(\"平均负载量\", \"LOAD\")"))
        // D119: iStat's LOAD row replaces the "CPU 占用" row on the page; the
        // readable usage is that row's third level (was
        // `processor.contains("CPU 占用")`).
        XCTAssertTrue(processor.contains("GeekProcessorUsageHoverDetail("))
        // D122 (2026-10-18): the usage page is a history page with the range
        // picker (was `GeekHoverDetailCanvas(title: L10n.text("CPU 占用",
        // "CPU Usage"))` around the usage ring).
        XCTAssertTrue(detail.contains("GeekHoverDetailCanvas(title: L10n.text(\"CPU 占用\", \"CPU Usage\"), showsRangePicker: true)"))
        // D39: the total reads the current reading (history's last point, or
        // the live one while the history is not prepared); was shown on the
        // page as `percentText(cpuCurrentReading?.cpuTotal)`.
        XCTAssertTrue(processor.contains("total: cpuCurrentReading?.cpuTotal"))
        XCTAssertTrue(processor.contains("percentText(geekCurrentCPUUserPercent)"))
        XCTAssertTrue(processor.contains("percentText(geekCurrentCPUSystemPercent)"))
        XCTAssertFalse(processor.contains("percentText(cpuBreakdown?."))
        XCTAssertTrue(detail.contains("GeekProcessorUsageHoverDetail"))
        XCTAssertTrue(detail.contains("L10n.text(\"总占用\", \"Total\")"))
        XCTAssertTrue(detail.contains("L10n.text(\"用户\", \"User\")"))
        XCTAssertTrue(detail.contains("L10n.text(\"系统\", \"System\")"))
    }

    func testMemoryProcessCardAllowsManualSelectionAndBatchQuitFromItsHeader() throws {
        let memory = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")

        XCTAssertTrue(memory.contains("GeekMemoryProcessSelectionMenu(store: store, tint: memoryTint)"))
        // Decision D2 (2026-10-04): "内存清理" is "退出所选应用" and no longer
        // falls back to the suggested apps (was: "内存清理" / "Clean Memory" and
        // store.ensureMemorySelectionForQuit()).
        // D139: in the form the header picks (was
        // `GeekMemoryQuitSelectedButton(store: store, tint: memoryTint)`).
        XCTAssertTrue(memory.contains("GeekMemoryQuitSelectedButton(store: store, tint: memoryTint, presentation: quitHint)"))
        XCTAssertTrue(memory.contains("@ObservedObject var store: ScanStore"))
        XCTAssertTrue(memory.contains("L10n.text(\"选择内存进程\", \"Select Memory Processes\")"))
        XCTAssertTrue(memory.contains("store.toggleMemoryAppUsageSelection(process)"))
        XCTAssertTrue(memory.contains("L10n.text(\"退出所选应用\", \"Quit Selected Apps\")"))
        XCTAssertFalse(memory.contains("store.ensureMemorySelectionForQuit()"))
        XCTAssertTrue(
            memory.contains(
                "store.requestQuitSelectedMemoryProcesses(presentConfirmationInMenuBar: true)"
            )
        )
        XCTAssertTrue(memory.contains("store.confirmQuitSelectedMemoryProcesses()"))
        XCTAssertTrue(memory.contains("store.cancelQuitSelectedMemoryProcesses()"))
        XCTAssertTrue(memory.contains("退出所选应用？"))
        XCTAssertTrue(memory.contains("store.isMemoryAppUsageSelected(process)"))
        XCTAssertTrue(memory.contains("\"checkmark.circle.fill\""))
        XCTAssertTrue(memory.contains("L10n.text(\"已选择退出\", \"Selected to quit\")"))
    }

    func testMemoryConfirmationBindingsDoNotTurnPassiveDismissalIntoCancellation() throws {
        let fixtures = [
            (
                try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift"),
                "private var confirmationBinding: Binding<Bool>",
                "var body: some View"
            ),
            (
                try source("Sources/StorageCleanerMac/Views/ContentView.swift"),
                "private var memoryBatchQuitAlertBinding: Binding<Bool>",
                "private var uninstallPreviewSheetBinding: Binding<Bool>"
            ),
        ]

        for (contents, startMarker, endMarker) in fixtures {
            let start = try XCTUnwrap(contents.range(of: startMarker)?.lowerBound)
            let end = try XCTUnwrap(
                contents.range(of: endMarker, range: start..<contents.endIndex)?.lowerBound
            )
            let binding = contents[start..<end]
            XCTAssertFalse(binding.contains("cancelQuitSelectedMemoryProcesses"))
        }
    }

    func testDiskCapacityBreakdownSeparatesRealFreeAndEstimatedReclaimableSpace() {
        let snapshot = StorageCapacitySnapshot(
            totalBytes: 1_000,
            availableBytes: 300,
            availableForImportantUsageBytes: 450
        )

        let breakdown = GeekDiskCapacityBreakdown(snapshot: snapshot)

        XCTAssertEqual(breakdown.totalBytes, 1_000)
        XCTAssertEqual(breakdown.usedBytes, 550)
        XCTAssertEqual(breakdown.reclaimableBytes, 150)
        XCTAssertEqual(breakdown.freeBytes, 300)
        XCTAssertEqual(breakdown.usedRatio, 0.55, accuracy: 0.000_1)
        XCTAssertEqual(breakdown.reclaimableRatio, 0.15, accuracy: 0.000_1)
    }

    func testDiskCapacityBreakdownNeverInventsReclaimableSpace() {
        let snapshot = StorageCapacitySnapshot(
            totalBytes: 1_000,
            availableBytes: 300,
            availableForImportantUsageBytes: 250
        )

        let breakdown = GeekDiskCapacityBreakdown(snapshot: snapshot)

        XCTAssertEqual(breakdown.usedBytes, 700)
        XCTAssertEqual(breakdown.reclaimableBytes, 0)
        XCTAssertEqual(breakdown.freeBytes, 300)
    }

    func testDiskHealthAgeUsesTheDiskReadingAndNeverDatesRetainedWearWithANewSnapshot() {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 20_000)
        func snapshot(remainingLifePercent: Int?) -> DiskHealthSnapshot {
            DiskHealthSnapshot(
                availability: .available, status: .healthy, smartStatus: .verified,
                isTRIMEnabled: true, fileSystem: "APFS", isFileVaultEnabled: nil,
                totalBytes: nil, availableBytes: nil,
                remainingLifePercent: remainingLifePercent,
                summaryText: nil, checkedAt: checkedAt
            )
        }
        XCTAssertEqual(GeekDiskHealthTimestamp.checkedAt(
            snapshot: snapshot(remainingLifePercent: 98), fallbackRemainingLifePercent: 99
        ), checkedAt)
        XCTAssertEqual(GeekDiskHealthTimestamp.checkedAt(
            snapshot: snapshot(remainingLifePercent: nil), fallbackRemainingLifePercent: nil
        ), checkedAt)
        XCTAssertNil(GeekDiskHealthTimestamp.checkedAt(
            snapshot: snapshot(remainingLifePercent: nil), fallbackRemainingLifePercent: 99
        ))
        XCTAssertNil(GeekDiskHealthTimestamp.checkedAt(snapshot: nil, fallbackRemainingLifePercent: 99))
        XCTAssertEqual(GeekDiskHealthTimestamp.ageText(checkedAt, now: checkedAt.addingTimeInterval(7_200)),
                       L10n.text("2 小时前", "2 hr ago"))
        XCTAssertEqual(GeekDiskHealthTimestamp.ageText(nil, now: checkedAt), L10n.text("时间未知", "Time unknown"))
        XCTAssertEqual(GeekDiskHealthTimestamp.ageText(checkedAt.addingTimeInterval(1), now: checkedAt),
                       L10n.text("时间未知", "Time unknown"))
    }

    func testCPUAxisAndDiskHealthDatesDescribeTheirActualSources() throws {
        let panel = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        let disk = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift")
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        XCTAssertFalse(panel.contains("浅色横线标记"))
        XCTAssertTrue(detail.contains("区间加权平均"))
        XCTAssertFalse(detail.contains("浅色线为实测总峰值"))
        XCTAssertFalse(panel.contains("CPU bars: each bar is one sample"))
        XCTAssertTrue(disk.contains("healthCheckedAt: volume.healthCheckedAt"))
        XCTAssertTrue(disk.contains("healthCheckedAt: volume.health.checkedAt"))
        XCTAssertTrue(disk.contains("Text(GeekDiskHealthTimestamp.ageText(volume.healthCheckedAt))"))
        XCTAssertTrue(detail.contains("value: GeekDiskHealthTimestamp.ageText(healthCheckedAt)"))
    }

    func testMemoryTopRowsShowTheirScopeAndOpenTheExistingFullProcessList() throws {
        let memory = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        XCTAssertTrue(memory.contains("geekMemoryTopProcesses.count)/\\(geekMemoryAllProcesses.count)"))
        XCTAssertTrue(memory.contains("进程组 · 前"))
        // D139: the scope is the title's help and VoiceOver value; the title
        // is iStat's PROCESSES (was the title itself).
        let scope = try XCTUnwrap(memory.components(separatedBy: "private var memoryProcessScopeText: String {").last?
            .components(separatedBy: "private var memoryProcessTitleHelp").first)
        XCTAssertTrue(scope.contains("进程组 · 前\\(geekMemoryTopProcesses.count)/\\(geekMemoryAllProcesses.count)项"))
        XCTAssertTrue(memory.contains("private var memoryProcessTitleText: String {\n        L10n.text(\"进程\", \"PROCESSES\")\n    }"))
        XCTAssertTrue(memory.contains("memoryProcessScopeText + L10n.text(\"。按应用"))
        XCTAssertTrue(memory.contains("accessibilityValue: memoryProcessScopeText"))
        XCTAssertTrue(memory.contains(".accessibilityValue(memoryProcessScopeText)"))
        let actions = try XCTUnwrap(memory.components(separatedBy: "private var memoryProcessActions: some View {").last?
            .components(separatedBy: "private var geekMemoryPagesCard").first)
        XCTAssertTrue(actions.contains("Button(L10n.text(\"查看全部\", \"View all\"))"))
        XCTAssertTrue(actions.contains("openApp(filter: .memory)"))
        let showAll = try XCTUnwrap(actions.range(of: "store.memoryShowsAllProcesses = true"))
        let navigate = try XCTUnwrap(actions.range(of: "openApp(filter: .memory)"))
        XCTAssertLessThan(showAll.lowerBound, navigate.lowerBound)
        XCTAssertTrue(actions.contains("只读查看全部已采样进程"))
        XCTAssertFalse(actions.contains("requestQuitSelectedMemoryProcesses"))
        XCTAssertTrue(actions.contains("GeekMemoryProcessSelectionMenu"))
        XCTAssertTrue(actions.contains("GeekMemoryQuitSelectedButton"))
    }

    func testLatestPanelPolishUsesGroupedMemoryAppsTruthfulDiskPeaksAndVisibleHoverFeedback() throws {
        let memory = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        let disk = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift")
        let network = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")
        let components = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift")
        let panel = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")

        XCTAssertTrue(memory.contains("store.menuBarPreparedMemoryApps"))
        // D138: iStat's 'Memory.Swap' (was "交换内存", "Swap Memory").
        XCTAssertTrue(memory.contains("Text(L10n.text(\"已使用的交换\", \"Swap\"))"))
        XCTAssertTrue(memory.contains("内存不够用时，macOS 暂时存放到磁盘上的数据"))
        // D119: iStat's swap bar replaces the 30 pt ring; the percentage is
        // the bar's share and VoiceOver's value (was `value: geekSwapPercentText`).
        XCTAssertTrue(memory.contains("GeekMemorySwapBar(progress: geekSwapProgress"))
        XCTAssertTrue(memory.contains("geekSwapPercentText]"))
        XCTAssertTrue(memory.contains("return used == 0 ? 0 : nil"))
        XCTAssertTrue(memory.contains("\\(usedText) · 未使用"))
        XCTAssertTrue(detail.contains("按需分配"))
        XCTAssertFalse(memory.contains("Capsule()"))
        // D146 (2026-10-19): iStat's 'Disks.Read' and 'Disks.Write' label the
        // peaks; the full names stay VoiceOver's (were
        // `title: L10n.text("读取峰值", "Read Peak")`, "写入峰值", "Write Peak").
        XCTAssertTrue(disk.contains("GeekIStatPeakValue(title: L10n.text(\"读\", \"Read\"), value: readPeak,"))
        XCTAssertTrue(disk.contains("GeekIStatPeakValue(title: L10n.text(\"写\", \"Write\"), value: writePeak,"))
        XCTAssertTrue(disk.contains("accessibilityLabel: L10n.text(\"读取峰值\", \"Read peak\")"))
        XCTAssertTrue(disk.contains("accessibilityLabel: L10n.text(\"写入峰值\", \"Write peak\")"))
        XCTAssertFalse(disk.contains("title: L10n.text(\"读取峰值\", \"Read Peak\")"))
        XCTAssertFalse(disk.contains("title: L10n.text(\"写入峰值\", \"Write Peak\")"))
        XCTAssertTrue(disk.contains("\"健康度 \\(remainingLifePercent)%"))
        XCTAssertFalse(disk.contains("\"健康度 \\(remainingLifePercent)% ·"))
        XCTAssertTrue(disk.contains("var geekPrimaryDiskHealthText: String?"))
        XCTAssertTrue(disk.contains("private var geekPrimaryDiskRemainingLifePercent: Int?"))
        XCTAssertTrue(disk.contains("?? healthSummary?.diskRemainingLifePercent"))
        XCTAssertTrue(disk.contains("remainingLifePercent: geekPrimaryDiskRemainingLifePercent"))
        XCTAssertTrue(disk.contains("case .unavailable:\n            return nil"))
        XCTAssertTrue(panel.contains("storageSnapshot.userAvailableBytes"))
        XCTAssertTrue(panel.contains("storageSnapshot.totalBytes"))
        XCTAssertTrue(panel.contains("destination: .disk"))
        XCTAssertFalse(panel.contains("if let diskHealthText = geekPrimaryDiskHealthText"))
        XCTAssertTrue(detail.contains("GeekDiskCapacityBreakdown(snapshot: snapshot)"))
        XCTAssertTrue(components.contains("isActive: isActive"))
        XCTAssertTrue(components.contains("isSelected: isSelected"))

        let publicAddress = try XCTUnwrap(network.range(of: "geekNetworkPublicAddress"))
        let localAddress = try XCTUnwrap(
            network.range(of: "geekNetworkLocalAddresses", range: publicAddress.upperBound..<network.endIndex)
        )
        XCTAssertLessThan(publicAddress.lowerBound, localAddress.lowerBound)
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try r2ProductionSource(at: projectRoot.appendingPathComponent(relativePath))
    }
}

@MainActor
private final class TertiaryHoverRecorder {
    private(set) var states: [Bool] = []

    func record(_ hovering: Bool) {
        states.append(hovering)
    }
}
