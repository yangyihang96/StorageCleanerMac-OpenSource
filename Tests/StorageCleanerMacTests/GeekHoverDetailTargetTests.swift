import CoreGraphics
import XCTest
@testable import StorageCleanerMac

final class GeekHoverDetailTargetTests: XCTestCase {
    func testHoverTimingKeepsAStableBridgeIntoTheAttachedThirdColumn() {
        XCTAssertEqual(HoverIntentPolicy.menuBar.initialOpenDelay, .zero)
        XCTAssertEqual(HoverIntentPolicy.menuBar.switchDelay, .zero)
        XCTAssertEqual(HoverIntentPolicy.menuBar.ordinaryCloseDelay, .milliseconds(260))
        XCTAssertEqual(HoverIntentPolicy.menuBar.corridorGraceDuration, .milliseconds(320))
    }

    @MainActor
    func testReferenceTertiaryDetailGeometryIsKeptExplicit() {
        XCTAssertEqual(GeekHoverDetailMetrics.historySize, CGSize(width: MiniWindowStyleTokens.historyWidth, height: 216))
        for size in [GeekHoverDetailMetrics.cpuHistorySize, GeekHoverDetailMetrics.memoryHistorySize, GeekHoverDetailMetrics.cpuUsageSize] {
            XCTAssertEqual(GeekPanelPresentationMetrics.normalizedTertiarySize(size), size)
        }
        XCTAssertEqual(GeekHoverDetailMetrics.compactHistorySize, CGSize(width: MiniWindowStyleTokens.compactHistoryWidth, height: 216))
        XCTAssertEqual(GeekHoverDetailMetrics.diskIOSize, CGSize(width: MiniWindowStyleTokens.historyWidth, height: 248))
        XCTAssertEqual(GeekHoverDetailMetrics.volumeSize, CGSize(width: 220, height: 339))
        XCTAssertEqual(GeekHoverDetailMetrics.vpnWidth, 220)
        XCTAssertEqual(GeekHoverDetailMetrics.uptimeSize, CGSize(width: 220, height: 136))
        XCTAssertEqual(GeekNetworkTertiaryView.referenceSize, CGSize(width: 255, height: 419))
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
        XCTAssertTrue(target.contains("&& !isPanelHoverEnvelopeActive"))
        XCTAssertTrue(tertiary.contains("!panelCoordinator.isPointerWithinHoverEnvelope"))
        XCTAssertTrue(tertiary.contains("panelCoordinator.dismissUnpinnedHierarchy()"))
        XCTAssertTrue(advanced.contains("panelCoordinator.scheduleHoverDismissal("))
        XCTAssertTrue(advanced.contains("scheduleTertiaryDetailDismissal(detail)"))
        XCTAssertTrue(advanced.contains("geekPanelHoverActivityState.reset()"))
        XCTAssertTrue(advanced.contains("panelCoordinator.dismissUnpinnedHierarchy()"))
    }

    func testSnapshotCaptureBlocksPointerHoverAtBothTertiaryEntryPoints() throws {
        let target = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let tertiary = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let session = try source("Sources/StorageCleanerMac/Support/MenuBarPanelSession.swift")
        let advanced = try source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")

        XCTAssertTrue(target.contains(
            "guard !MiniWindowDemoData.isCapturingMenuBarPanelSnapshots else { return }"
        ))
        XCTAssertTrue(tertiary.contains(
            "guard !MiniWindowDemoData.isCapturingMenuBarPanelSnapshots else { return }"
        ))
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
        XCTAssertEqual(disk.components(separatedBy: "GeekHoverDetailTarget(").count - 1, 2)

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

        XCTAssertFalse(detail.contains("L10n.text(\"历史趋势\", \"History Trend\")"))
        XCTAssertTrue(detail.contains("GPU 内存"))
        XCTAssertFalse(detail.contains("频率 / FPS"))
        XCTAssertFalse(detail.contains("value: \"-- / --\""))
        XCTAssertFalse(detail.contains("Text(pressureExplanation)"))
    }

    func testNetworkTrendConnectionAndVPNUseSharedAttachedHoverDetail() throws {
        let network = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")

        XCTAssertEqual(network.components(separatedBy: "GeekHoverDetailTarget(").count - 1, 3)
        XCTAssertTrue(network.contains("GeekHoverDetailMetrics.compactHistorySize"))
        XCTAssertTrue(network.contains("GeekNetworkHistoryHoverDetail("))
        XCTAssertTrue(network.contains(
            "isLoading: !store.isMenuBarRefreshPaused && networkTopologySnapshot == nil && networkInterfaceSnapshot == nil"
        ))
        XCTAssertTrue(network.contains("popoverSize: GeekNetworkTertiaryView.referenceSize"))
        XCTAssertTrue(network.contains("GeekNetworkTertiaryView("))
        XCTAssertTrue(network.contains("snapshot: networkInterfaceSnapshot"))
        XCTAssertTrue(network.contains("topology: networkTopologySnapshot"))
        XCTAssertTrue(network.contains("refresh: refreshPanelData"))
        XCTAssertTrue(network.contains("network.connection.inspector"))
        XCTAssertFalse(network.contains("ControlPaletteHoverAnchor("))
        XCTAssertTrue(network.contains("GeekVPNDisclosure"))
        XCTAssertTrue(network.contains("GeekVPNHoverDetail.preferredSize(for: tunnel)"))
        XCTAssertTrue(network.contains("GeekHoverDetailMetrics.vpnWidth"))
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
        XCTAssertTrue(detail.contains(".padding(GeekPanelLayout.contentPadding)"))
        XCTAssertFalse(detail.contains(
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"
        ))
        let batteryBody = try XCTUnwrap(
            sensorPower.components(separatedBy: "struct GeekBatteryElectricalHoverDetail").last?
                .components(separatedBy: "private var batteryRows").first
        )
        XCTAssertFalse(batteryBody.contains("maxHeight: .infinity"))
        XCTAssertTrue(network.contains("popoverSize: GeekHoverDetailMetrics.compactHistorySize"))
        XCTAssertTrue(power.contains("popoverSize: GeekSensorPowerHoverDetailMetrics.batterySize"))
    }

    func testEveryHoverDetailUsesItsMeasuredOwningRowTop() throws {
        let target = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let detailHost = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")

        XCTAssertTrue(target.contains("proxy.frame(in: .named(GeekTertiarySourceCoordinateSpace.name)).minY"))
        XCTAssertTrue(target.contains("measuredSourceOffset = max(0, offset)"))
        XCTAssertTrue(detailHost.contains(".coordinateSpace(name: GeekTertiarySourceCoordinateSpace.name)"))
    }

    func testOnDemandSnapshotFreshnessHasExplicitCurrentAndStaleStates() {
        XCTAssertEqual(GeekOnDemandSnapshotFreshness.refreshInterval, 2)
        let sampleStart = Date(timeIntervalSince1970: 5_000)
        XCTAssertFalse(GeekOnDemandSnapshotFreshness.shouldRefresh(startedAt: sampleStart, now: sampleStart.addingTimeInterval(1.8)))
        XCTAssertTrue(GeekOnDemandSnapshotFreshness.shouldRefresh(startedAt: sampleStart, now: sampleStart.addingTimeInterval(2)))
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
            XCTAssertFalse(source.contains("平均负载"))
            XCTAssertFalse(source.contains("Load Average"))
        }
        XCTAssertTrue(processor.contains("CPU 占用"))
        XCTAssertTrue(processor.contains("percentText(cpuChartHistory.last?.cpuTotal)"))
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
        XCTAssertTrue(memory.contains("GeekMemoryCleanupButton(store: store, tint: memoryTint)"))
        XCTAssertTrue(memory.contains("@ObservedObject var store: ScanStore"))
        XCTAssertTrue(memory.contains("L10n.text(\"选择内存进程\", \"Select Memory Processes\")"))
        XCTAssertTrue(memory.contains("store.toggleMemoryAppUsageSelection(process)"))
        XCTAssertTrue(memory.contains("L10n.text(\"内存清理\", \"Clean Memory\")"))
        XCTAssertTrue(memory.contains("store.ensureMemorySelectionForQuit()"))
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
        XCTAssertTrue(memory.contains("L10n.text(\"已选择清理\", \"Selected for cleanup\")"))
    }

    func testMemoryConfirmationBindingsDoNotTurnPassiveDismissalIntoCancellation() throws {
        let fixtures = [
            (
                try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift"),
                "private var confirmationBinding: Binding<Bool>",
                "var body: some View"
            ),
            (
                try source("Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"),
                "private var memoryBatchQuitAlertBinding: Binding<Bool>",
                "private var snapshot: MemorySnapshot?"
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
        XCTAssertTrue(actions.contains("GeekMemoryCleanupButton"))
    }

    func testLatestPanelPolishUsesGroupedMemoryAppsTruthfulDiskPeaksAndVisibleHoverFeedback() throws {
        let memory = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        let disk = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift")
        let network = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")
        let components = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift")
        let panel = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        let detail = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")

        XCTAssertTrue(memory.contains("store.menuBarPreparedMemoryApps"))
        XCTAssertTrue(memory.contains("Text(L10n.text(\"交换内存\", \"Swap Memory\"))"))
        XCTAssertTrue(memory.contains("内存不够用时，macOS 暂时存放到磁盘上的数据"))
        XCTAssertTrue(memory.contains("value: geekSwapPercentText"))
        XCTAssertTrue(memory.contains("return used == 0 ? 0 : nil"))
        XCTAssertTrue(memory.contains("\\(usedText) · 未使用"))
        XCTAssertTrue(detail.contains("L10n.text(\"按需分配\", \"On Demand\")"))
        XCTAssertFalse(memory.contains("Capsule()"))
        XCTAssertTrue(disk.contains("title: L10n.text(\"读取峰值\", \"Read Peak\")"))
        XCTAssertTrue(disk.contains("title: L10n.text(\"写入峰值\", \"Write Peak\")"))
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
        try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

@MainActor
private final class TertiaryHoverRecorder {
    private(set) var states: [Bool] = []

    func record(_ hovering: Bool) {
        states.append(hovering)
    }
}
