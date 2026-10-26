#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D119: the module pages (level two) follow iStat Menus 7.30's module menus
/// (`round2/istat/istat-preview-*.jpg`, the static `setWidth:` and section
/// constants). Renders the production pages offscreen with the demo snapshot
/// and the demo processes: no sampling, window or user data.
@MainActor
final class MiniWindowIStatModuleLayoutTests: XCTestCase {
    func testProcessorPageHasTheIStatSections() async throws {
        let page = try ModulePage(for: self, section: .processor)
        defer { page.tearDown() }
        try await page.loadDemoHistory()
        let bitmap = try page.render(mode: .black)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 272, accuracy: 0.5, "iStat's CPU menu is 272 pt wide")

        // The CPU graph 120, the cores, five processes 25 + 17 × 5, the GPU 87,
        // the load and the uptime 25 each, 7 pt apart inside the 8 pt shell.
        let cores = GeekProcessorCoreLayout.cardHeight(for: ProcessInfo.processInfo.processorCount, groupCount: 1)
        let sections: [CGFloat] = [120, cores, 110, 87, 25, 25]
        let expected = sections.reduce(0, +) + 7 * CGFloat(sections.count - 1) + 16
        XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, expected, accuracy: 0.5)
        try page.exportBothModes(name: "l2-cpu", first: bitmap)
    }

    func testMemoryPageHasTheIStatSections() throws {
        let page = try ModulePage(for: self, section: .memory)
        defer { page.tearDown() }
        let bitmap = try page.render(mode: .black)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 270, accuracy: 0.5, "iStat's memory menu is 270 pt wide")

        // The rings 112, the composition 76, five processes 25 + 17 × 5 with
        // our actions on the title's row, the swap activity 42, the swap 40
        // and our data row 25, 7 pt apart inside the 8 pt shell. D139: the
        // title is iStat's PROCESSES and the dimmed quit button takes its
        // short title, so the actions fit beside it (was `actionsOnOwnRow:
        // true`, 127: at 270 pt they did not fit until apps were selected).
        let processes = GeekMemoryProcessLayout.cardHeight(rowCapacity: 5, actionsOnOwnRow: false)
        XCTAssertEqual(processes, 110)
        let sections: [CGFloat] = [112, 76, processes, 42, 40, 25]
        let expected = sections.reduce(0, +) + 7 * CGFloat(sections.count - 1) + 16
        XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, expected, accuracy: 0.5)
        // D140 (2026-10-19): the page's first size is the rendered one, 456
        // (D139 left it at 473, the card at 127).
        XCTAssertEqual(GeekPanelPresentationMetrics.detailSize(for: .memory).height, expected)
        try page.exportBothModes(name: "l2-memory", first: bitmap)
    }

    /// D140: in the complex density the memory page has three processes and
    /// the network page two, each page's first size its rendered height: the
    /// memory page's rings 112, composition 76, processes 25 + 17 × 3 and
    /// data row 25 (D139: 326, was 343 with the actions' row); the network
    /// page's bandwidth 150, interface 25, IP sections 27 each and processes
    /// 25 + 17 × 2 (332, was 344).
    func testComplexPagesMatchTheirFirstSizes() async throws {
        for (section, sections) in [
            (PanelSection.memory, [CGFloat(112), 76, GeekIStatSectionGeometry.processesHeight(3), 25]),
            (.network, [150, 25, 27, 27, GeekIStatSectionGeometry.processesHeight(2)]),
        ] {
            let page = try ModulePage(for: self, section: section, density: .complex)
            defer { page.tearDown() }
            if section == .network { try await page.loadDemoHistory() }
            let bitmap = try page.render(mode: .black)
            let expected = sections.reduce(0, +) + 7 * CGFloat(sections.count - 1) + 16
            XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, expected, accuracy: 0.5, "\(section)")
            XCTAssertEqual(GeekPanelPresentationMetrics.detailSize(for: section, density: .complex).height,
                           expected, "\(section)")
        }
        XCTAssertEqual(GeekPanelPresentationMetrics.detailSize(for: .memory, density: .complex).height, 326)
        XCTAssertEqual(GeekPanelPresentationMetrics.detailSize(for: .network, density: .complex).height, 332)
    }

    /// D126: the memory cleanup (one of our four features) in iStat's parts.
    /// With apps selected iStat's destructive button item follows the process
    /// card: 31 pt, the red gradient from (1, 0.242, 0.246) to (1, 0.082,
    /// 0.086) inside its 2 pt inset. The card is iStat's 25 + 17 × 5, one row
    /// more where the actions still take their own row (`ViewThatFits`; the
    /// header's quit button hides once apps are selected).
    func testMemoryPageWithSelectedAppsEndsTheListWithTheIStatQuitItem() throws {
        let item = GeekIStatInterfaceGeometry.buttonHeight
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let page = try ModulePage(for: self, section: .memory)
            defer { page.tearDown() }
            // The demo's selection (`menu.memory.processes.selected`).
            page.store.selectedMemoryProcessIDs = [201, 202, 204]
            XCTAssertEqual(page.store.selectedMemoryAppCount, 3, "\(language)")
            XCTAssertTrue(GeekMemoryQuitSelection.isAvailable(store: page.store), "the item is drawn enabled")
            for mode in [MiniWindowVisualMode.black, .graphite] {
                let bitmap = try page.render(mode: mode)
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 270, accuracy: 0.5)
                // Left of the centered label, beyond the item's 6 pt corners.
                func color(_ y: CGFloat) throws -> NSColor {
                    try XCTUnwrap(bitmap.colorAt(x: 22 * 2, y: Int(y * 2))?.usingColorSpace(.sRGB))
                }
                func isRed(_ color: NSColor) -> Bool { color.redComponent > 0.9 && color.greenComponent < 0.35 }
                // The item follows the rings 112, the composition 76 and the
                // process card (110, or 127 with the actions on their own
                // row), 7 pt apart inside the 8 pt shell.
                let tops = [false, true].map {
                    8 + 112 + 7 + 76 + 7 + GeekMemoryProcessLayout.cardHeight(rowCapacity: 5, actionsOnOwnRow: $0) + 7
                }
                XCTAssertEqual(tops, [327, 344])
                let found = try tops.filter { try isRed(color($0 + 5)) && isRed(color($0 + item - 5)) }
                XCTAssertEqual(found.count, 1, "\(language) \(mode): the red item at one of \(tops)")
                let itemTop = try XCTUnwrap(found.first)
                // The gradient inside the 2 pt inset, lighter at the top.
                XCTAssertFalse(isRed(try color(itemTop + 1)), "\(language) \(mode)")
                XCTAssertFalse(isRed(try color(itemTop + item - 1)), "\(language) \(mode)")
                XCTAssertGreaterThan(try color(itemTop + 5).greenComponent - color(itemTop + item - 5).greenComponent,
                                     0.05, "lighter at the top: \(language) \(mode)")
                // Then the swap activity 42, the swap 40 and the data row 25.
                let expected = itemTop + item + 7 + 42 + 7 + 40 + 7 + 25 + 8
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, expected, accuracy: 0.5, "\(language) \(mode)")
            }
            try page.exportBothModes(name: "l2-memory-selected-\(language == .english ? "en" : "zh")",
                                     first: try page.render(mode: .black))
        }
    }

    /// D139: iStat draws PROCESSES alone on the title row; our actions share
    /// it in both languages, with and without apps selected, so the process
    /// card is iStat's 25 + 17 × 5 (English with nothing selected was 127:
    /// "PROCESS GROUPS · 5/5" and the three actions did not fit on one row).
    /// There the dimmed quit button takes its short title.
    func testMemoryProcessActionsShareTheTitleRowInBothLanguages() throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for selected in [Set<Int32>(), [201, 202, 204]] {
                let page = try ModulePage(for: self, section: .memory)
                defer { page.tearDown() }
                // The demo's selection (`menu.memory.processes.selected`).
                page.store.selectedMemoryProcessIDs = selected
                XCTAssertEqual(page.store.selectedMemoryAppCount, selected.count)
                let bitmap = try page.render(mode: .black)
                let tag = "\(language) \(selected.count) selected"
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 270, accuracy: 0.5, tag)
                // The rings 112, the composition 76, the process card 110, the
                // swap activity 42, the swap 40 and the data row 25, 7 pt
                // apart inside the 8 pt shell; with apps selected the 31 pt
                // quit item follows the card.
                let processes = GeekMemoryProcessLayout.cardHeight(rowCapacity: 5, actionsOnOwnRow: false)
                let sections: [CGFloat] = [112, 76, processes, 42, 40, 25]
                    + (selected.isEmpty ? [] : [GeekIStatInterfaceGeometry.buttonHeight])
                let expected = sections.reduce(0, +) + 7 * CGFloat(sections.count - 1) + 16
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, expected, accuracy: 0.5, tag)
                try page.exportBothModes(
                    name: "l2-memory-header-\(language == .english ? "en" : "zh")-\(selected.isEmpty ? "none" : "selected")",
                    first: bitmap)
            }
        }
    }

    /// D126: the quit result is iStat's text section, the major label and
    /// seven label and value rows (27 + 17 × 7) with our note below them,
    /// then "完成" and "查看报告" as standard button items (31 pt each); the
    /// swap activity stays hidden while the result shows.
    func testMemoryQuitResultIsAnIStatTextSectionWithButtonItems() throws {
        XCTAssertEqual(GeekIStatTextSectionGeometry.height(labelRows: 8, tickRows: 0), 146)
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let page = try ModulePage(for: self, section: .memory)
            defer { page.tearDown() }
            let result = MiniWindowDemoData.memoryQuitResult
            page.store.memoryOptimizationResult = result
            let bitmap = try page.render(mode: .black)
            XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 270, accuracy: 0.5)
            // The note wraps inside the section's 8 pt insets on the page's
            // 254 pt content width.
            let note = NSHostingView(rootView: Text(result.detail).geekIStatSectionNote()
                .frame(width: 270 - 16).fixedSize(horizontal: false, vertical: true)).fittingSize.height
            XCTAssertGreaterThan(note, 15, "\(language)")
            let section = GeekIStatTextSectionGeometry.height(labelRows: 8, tickRows: 0) + note
            let item = GeekIStatInterfaceGeometry.buttonHeight
            let sections: [CGFloat] = [112, 76, section, item, item, 40, 25]
            let expected = sections.reduce(0, +) + 7 * CGFloat(sections.count - 1) + 16
            XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, expected, accuracy: 1, "\(language)")
            try page.exportBothModes(name: "l2-memory-quit-result-\(language == .english ? "en" : "zh")",
                                     first: bitmap)
        }
        let memory = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        XCTAssertFalse(memory.contains(".borderedProminent"), "no bordered buttons on the memory page")
        XCTAssertFalse(memory.contains("GeekCombinedCard(height: 220)"), "the 220 pt result card is gone")
        XCTAssertTrue(memory.contains("GeekIStatButtonItem(title: GeekMemoryQuitSelection.prominentTitle(selectedCount: selectedCount),\n"
            + "                                kind: .destructive) {\n"
            + "                GeekMemoryQuitSelection.request(store: store)"), "the quit item asks for confirmation first")
        XCTAssertTrue(memory.contains("store.requestQuitSelectedMemoryProcesses(presentConfirmationInMenuBar: true)"))
    }

    func testDiskPageHasTheIStatSections() throws {
        let page = try ModulePage(for: self, section: .disk)
        defer { page.tearDown() }
        // The demo volume and a fixture network drive; the demo disk activity
        // moved to now.
        let capacity = StorageCapacitySnapshot(totalBytes: 4_000_000_000_000, availableBytes: 1_100_000_000_000)
        let drive = MountedStorageVolumeSnapshot(
            kind: .network, url: URL(fileURLWithPath: "/Volumes/Fixture Drive"), name: "Fixture Drive",
            capacity: capacity,
            health: DiskHealthSnapshot(availability: .unavailable, status: .unavailable, smartStatus: .unsupported,
                                       isTRIMEnabled: nil, fileSystem: "smbfs", isInternal: false,
                                       totalBytes: capacity.totalBytes, availableBytes: capacity.availableBytes,
                                       summaryText: nil, checkedAt: Date()),
            remainingLifePercent: nil, temperatureCelsius: nil
        )
        let auxiliary = page.store.menuBarAuxiliaryMonitorState
        auxiliary.seedVolumesForTesting(storageSnapshot: MiniWindowDemoData.storageSnapshot,
                                        volumeName: MiniWindowDemoData.volumeName,
                                        networkStorageVolumes: [drive])
        let offset = Date().timeIntervalSince(MiniWindowDemoData.referenceDate)
        auxiliary.restoreHistory(MetricHistorySnapshot(diskIO: MiniWindowDemoData.nativeDiskIOHistory.map {
            NativeDiskIOPoint(date: $0.date.addingTimeInterval(offset), readBytesPerSecond: $0.readBytesPerSecond,
                              writeBytesPerSecond: $0.writeBytesPerSecond,
                              readOperationsPerSecond: $0.readOperationsPerSecond,
                              writeOperationsPerSecond: $0.writeOperationsPerSecond)
        }))
        let bitmap = try page.render(mode: .black)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 301, accuracy: 0.5, "iStat's disk menu is 301 pt wide")

        // One volume 42, the network disks with one drive 24 + 17, the
        // activity 130 and five processes 25 + 17 × 5, 7 pt apart inside the
        // 8 pt shell.
        XCTAssertEqual(GeekDiskVolumeLayout.cardHeight, 42)
        XCTAssertEqual(GeekDiskIOCardLayout.cardHeight, 130)
        let sections: [CGFloat] = [42, 41, 130, GeekSecondaryTransferLayout.processCardHeight(rowCount: 5)]
        XCTAssertEqual(sections[3], 110)
        let expected = sections.reduce(0, +) + 7 * CGFloat(sections.count - 1) + 16
        XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, expected, accuracy: 0.5)
        // Without network drives the page is the nominal size.
        XCTAssertEqual(GeekPanelPresentationMetrics.detailSize(for: .disk).height, expected - 41 - 7)
        try page.exportBothModes(name: "l2-disk", first: bitmap)
    }

    /// D136: iStat's visibility button appends the volume's key to the
    /// stored list, rebuilds the menu without it and closes the submenu,
    /// pinned or not; with every volume hidden the menu lists none.
    func testDiskPageLeavesHiddenVolumesOutAndHidingClosesThePage() throws {
        let page = try ModulePage(for: self, section: .disk)
        defer { page.tearDown() }
        let capacity = StorageCapacitySnapshot(totalBytes: 4_000_000_000_000, availableBytes: 1_100_000_000_000)
        let drive = MountedStorageVolumeSnapshot(
            kind: .network, url: URL(fileURLWithPath: "/Volumes/Fixture Drive"), name: "Fixture Drive",
            capacity: capacity,
            health: DiskHealthSnapshot(availability: .unavailable, status: .unavailable, smartStatus: .unsupported,
                                       isTRIMEnabled: nil, fileSystem: "smbfs", isInternal: false,
                                       totalBytes: capacity.totalBytes, availableBytes: capacity.availableBytes,
                                       summaryText: nil, checkedAt: Date()),
            remainingLifePercent: nil, temperatureCelsius: nil
        )
        XCTAssertEqual(drive.id, "/Volumes/Fixture Drive", "a mounted volume's key is its mount path")
        page.store.menuBarAuxiliaryMonitorState.seedVolumesForTesting(
            storageSnapshot: MiniWindowDemoData.storageSnapshot,
            volumeName: MiniWindowDemoData.volumeName,
            networkStorageVolumes: [drive]
        )
        let processes = GeekSecondaryTransferLayout.processCardHeight(rowCount: 5)
        let full: CGFloat = 42 + 41 + 130 + processes + 7 * 3 + 16
        XCTAssertEqual(CGFloat(try page.render(mode: .black).pixelsHigh) / 2, full, accuracy: 0.5)

        // The volume's page is open and pinned when its button is clicked.
        let coordinator = page.view.panelCoordinator
        XCTAssertTrue(coordinator.presentHistory(.inline(UUID()), pinned: true))
        XCTAssertTrue(coordinator.isHistoryPinned)
        page.view.hideDiskVolume("/")
        XCTAssertEqual(coordinator.route, .module(.disk), "hiding closes the volume's page")
        XCTAssertFalse(coordinator.isHistoryPinned)
        let stored = { MiniWindowHiddenItems.keys(from: page.defaults.string(forKey: MiniWindowHiddenItems.disksKey) ?? "") }
        XCTAssertEqual(stored(), ["/"], "in the panel's preference store")
        XCTAssertEqual(CGFloat(try page.render(mode: .black).pixelsHigh) / 2, full - 42 - 7, accuracy: 0.5,
                       "the startup volume's card goes, no loading row takes its place, the drive stays")

        // The network drive too: no volume sections at all.
        page.view.hideDiskVolume(drive.id)
        XCTAssertEqual(stored(), ["/", "/Volumes/Fixture Drive"])
        let allHidden = try page.render(mode: .black)
        XCTAssertEqual(CGFloat(allHidden.pixelsHigh) / 2, 130 + processes + 7 + 16, accuracy: 0.5)
        try page.exportBothModes(name: "l2-disk-all-hidden", first: allHidden)

        // Settings' Show Hidden Disks empties the list (the same key and
        // store); the page is whole again. A live panel observes the key's
        // writes from Settings; this detached view keeps its own last value,
        // so the list is emptied through it.
        page.view.hiddenDiskKeysRaw = ""
        XCTAssertEqual(stored(), [])
        XCTAssertEqual(CGFloat(try page.render(mode: .black).pixelsHigh) / 2, full, accuracy: 0.5)
    }

    func testNetworkPageHasTheIStatSections() async throws {
        let page = try ModulePage(for: self, section: .network)
        defer { page.tearDown() }
        try await page.loadDemoHistory()
        // No interface, address or process sample: the reading states, so the
        // evidence shows no address.
        let bitmap = try page.render(mode: .black)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 301, accuracy: 0.5, "iStat's network menu is 301 pt wide")

        // The bandwidth 150, the interface 25, the public and the local IP
        // sections while reading and four processes 25 + 17 × 4, 7 pt apart
        // inside the 8 pt shell. D140: iStat's IP section without an
        // address is its label, 27 (were 25 and 41: the IPv4 address in the
        // title row, IPv6 below; the page 378).
        XCTAssertEqual(GeekNetworkBandwidthLayout.cardHeight, 150)
        let sections: [CGFloat] = [150, 25, 27, 27, GeekIStatSectionGeometry.processesHeight(4)]
        XCTAssertEqual(sections[4], 93)
        let expected = sections.reduce(0, +) + 7 * CGFloat(sections.count - 1) + 16
        XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, expected, accuracy: 0.5)
        XCTAssertEqual(GeekPanelPresentationMetrics.detailSize(for: .network).height, expected)
        try page.exportBothModes(name: "l2-network", first: bitmap)
    }

    func testSensorsPageHasTheIStatGroups() throws {
        let page = try ModulePage(for: self, section: .sensors)
        defer { page.tearDown() }
        // The demo battery, power and processor readings, taken now.
        var power = MiniWindowDemoData.powerTelemetry
        power.generatedAt = Date()
        page.store.menuBarAuxiliaryMonitorState.seedSensorsForTesting(
            battery: MiniWindowDemoData.batterySnapshot, electrical: MiniWindowDemoData.batteryElectricalSnapshot,
            power: power, processor: MiniWindowDemoData.processorTelemetry, at: Date())
        let bitmap = try page.render(mode: .black)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 301, accuracy: 0.5, "iStat's sensors menu is 301 pt wide")

        // iStat's order: the rings 88, then a titled group per kind, 24 + 17n.
        // The demo Mac: twelve temperature zones and the probes row, one fan
        // with the control entry, one current, five power rows and the
        // helper's row, one voltage, four frequencies and the ambient light;
        // 7 pt apart inside the 8 pt shell.
        XCTAssertEqual(GeekSensorSummaryLayout.cardHeight, 88)
        let group = { (rows: Int) in GeekIStatSectionGeometry.rowsHeight(rows, titled: true) }
        let sections: [CGFloat] = [88, group(13), group(2), group(1), group(6), group(1), group(4), group(1)]
        let expected = sections.reduce(0, +) + 7 * CGFloat(sections.count - 1) + 16
        XCTAssertEqual(expected, 797)
        XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, expected, accuracy: 0.5)
        try page.exportBothModes(name: "l2-sensors", first: bitmap)
    }

    func testPowerPageHasTheIStatSections() async throws {
        let page = try ModulePage(for: self, section: .power, powerModes: ModulePageDemoPowerModes())
        defer { page.tearDown() }
        // The demo battery and its last hour, moved to now, and the demo
        // energy modes (read, never written).
        var power = MiniWindowDemoData.powerTelemetry
        power.generatedAt = Date()
        let auxiliary = page.store.menuBarAuxiliaryMonitorState
        auxiliary.seedSensorsForTesting(
            battery: MiniWindowDemoData.batterySnapshot, electrical: MiniWindowDemoData.batteryElectricalSnapshot,
            power: power, processor: MiniWindowDemoData.processorTelemetry, at: Date())
        let offset = Date().timeIntervalSince(MiniWindowDemoData.referenceDate)
        auxiliary.restoreHistory(MetricHistorySnapshot(power: MiniWindowDemoData.powerHistory.map {
            MenuBarPowerHistoryPoint(date: $0.date.addingTimeInterval(offset), chargePercent: $0.chargePercent,
                                     batteryPowerWatts: $0.batteryPowerWatts, isCharging: $0.isCharging,
                                     powerSource: $0.powerSource)
        }))
        await page.healthStore.refreshBatteryPowerModes()
        XCTAssertFalse(page.healthStore.batteryPowerModes.supportedBatteryModes.isEmpty)
        let bitmap = try page.render(mode: .black)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, 240, accuracy: 0.5, "iStat's battery menu is 240 pt wide")

        // The battery card 112, the charge chart 80, the energy mode 25 and
        // the demo's two apps 25 + 17 × 2, 7 pt apart inside the 8 pt shell;
        // the nominal page lists three apps.
        let apps = min(GeekPowerLayout.displayedEnergyAppCount, MiniWindowDemoData.preparedProcesses.energy.count)
        XCTAssertEqual(apps, 2)
        let sections: [CGFloat] = [112, 80, 25, GeekIStatSectionGeometry.processesHeight(apps)]
        let expected = sections.reduce(0, +) + 7 * CGFloat(sections.count - 1) + 16
        XCTAssertEqual(expected, 313)
        XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, expected, accuracy: 0.5)
        XCTAssertEqual(GeekPanelPresentationMetrics.detailSize(for: .power).height,
                       expected + GeekIStatSectionGeometry.rowPitch)
        try page.exportBothModes(name: "l2-power", first: bitmap)
    }

    /// D126: the cleanup page has had no entry in the mini window since 1.9.2
    /// and iStat has no such menu; rendered with the inert smart scan fixture
    /// (no scanner, no executor) for the keep-or-delete review.
    func testRenderedCleanupPageForReview() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let page = try ModulePage(for: self, section: .cleanup)
            defer { page.tearDown() }
            page.store.installDebugSmartScanSessionFixture(.results)
            // The page's own model, prepared as the opened page prepares it.
            let model = page.view.cleanupDetailsModel
            model.start(MiniWindowCleanupSource(store: page.store))
            defer { model.stop() }
            for _ in 0..<400 where !model.isInitialLayoutReady || model.isPreparing {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(model.isInitialLayoutReady, "the fixture session was prepared")
            let bitmap = try page.render(mode: .black)
            XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, GeekPanelPresentationMetrics.detailWidth(for: .cleanup),
                           accuracy: 0.5)
            try page.exportBothModes(name: "l2-cleanup-\(language == .english ? "en" : "zh")", first: bitmap)
        }
    }

    func testIStatSectionFormulas() {
        // 2x previews: four text rows 76, a sensor group with one row 41, three
        // processes 76, a single title row 25.
        XCTAssertEqual(GeekIStatSectionGeometry.rowsHeight(4, titled: false), 76)
        XCTAssertEqual(GeekIStatSectionGeometry.rowsHeight(2, titled: false), 42)
        XCTAssertEqual(GeekIStatSectionGeometry.rowsHeight(1, titled: true), 41)
        XCTAssertEqual(GeekIStatSectionGeometry.processesHeight(3), 76)
        XCTAssertEqual(GeekMemoryProcessLayout.cardHeight(rowCapacity: 3, actionsOnOwnRow: false), 76)
        XCTAssertEqual(GeekMemoryProcessLayout.rowsHeight(5), 83)
        XCTAssertEqual(GeekIStatSectionGeometry.singleRowHeight, 25)
        XCTAssertEqual(GeekIStatSectionGeometry.rowTop(0, titled: true), 22)
        XCTAssertEqual(GeekIStatSectionGeometry.rowTop(2, titled: false), 39)
        // The CPU preview's twelve cores of two types.
        XCTAssertEqual(GeekProcessorCoreLayout.cardHeight(for: 12, groupCount: 2), 66)
        XCTAssertEqual(GeekPanelPresentationMetrics.detailWidth(for: .processor), 272)
        XCTAssertEqual(GeekPanelPresentationMetrics.detailWidth(for: .memory), 270)
        XCTAssertEqual(GeekPanelPresentationMetrics.detailWidth(for: .power), 240)
        for section in [PanelSection.disk, .network, .sensors, .cleanup] {
            XCTAssertEqual(GeekPanelPresentationMetrics.detailWidth(for: section), 301, "\(section)")
            XCTAssertEqual(GeekPanelPresentationMetrics.detailSize(for: section).width, 301, "\(section)")
        }
    }

    /// The spread layout puts the first ring at the leading edge and the last
    /// at the trailing edge, as on the CPU preview's twelve cores and four
    /// GPU rings, and wraps at the minimum spacing.
    func testSpreadLayoutPlacesRingsEdgeToEdge() {
        XCTAssertEqual(GeekIStatSpreadLayout.columns(count: 12, itemSize: 18, minimumSpacing: 2, width: 240), 12)
        XCTAssertEqual(GeekIStatSpreadLayout.columns(count: 13, itemSize: 18, minimumSpacing: 2, width: 240), 12)
        XCTAssertEqual(GeekIStatSpreadLayout.rows(count: 13, columns: 12), 2)
        XCTAssertEqual(GeekIStatSpreadLayout.columns(count: 4, itemSize: 54, minimumSpacing: 2, width: 240), 4)
    }
}

@MainActor
private final class ModulePage {
    let suiteName: String
    let defaults: UserDefaults
    let store: ScanStore
    let view: MenuBarAdvancedStatusView
    let healthStore: ComputerHealthStore
    let section: PanelSection

    init(for testCase: XCTestCase, section: PanelSection,
         powerModes: (any BatteryPowerModeControlling)? = nil,
         density: PanelDensity = .geek) throws {
        self.section = section
        suiteName = TestPreferenceDomain.makeSuite()
        defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
        store = try ScanStore.makeForTests(for: testCase, cleanupPreferences: defaults, cleanReportLoader: { [] })
        store.menuBarMonitorState.update(try XCTUnwrap(MiniWindowDemoData.presentationSnapshot(live: nil, usesDemoData: true)))
        // The pages' open tasks read nothing from this Mac: no charge limit
        // (the power page) and no battery-settings check, so the evidence
        // holds demo data only.
        store.menuBarAuxiliaryMonitorState.setChargeLimitDataOnlyFixture(true)
        store.publishMenuBarPreparedProcessesForTesting(MiniWindowDemoData.preparedProcesses,
                                                         memoryApps: MiniWindowDemoData.memorySnapshot.appsByResidentUsage)
        // The demo memory sample, taken now (its own date is the demo's
        // reference date, which the page would show as expired).
        let memory = MiniWindowDemoData.memorySnapshot
        store.memorySnapshot = MemorySnapshot(
            generatedAt: Date(), physicalBytes: memory.physicalBytes, freeBytes: memory.freeBytes,
            inactiveBytes: memory.inactiveBytes, speculativeBytes: memory.speculativeBytes,
            fileBackedBytes: memory.fileBackedBytes, purgeableBytes: memory.purgeableBytes,
            wiredBytes: memory.wiredBytes, compressedBytes: memory.compressedBytes,
            swapUsedBytes: memory.swapUsedBytes, pressureFreePercentage: memory.pressureFreePercentage,
            pressureSummary: memory.pressureSummary, topProcesses: memory.topProcesses,
            swapTotalBytes: memory.swapTotalBytes, swappedInBytes: memory.swappedInBytes,
            swappedOutBytes: memory.swappedOutBytes, measurements: memory.measurements,
            quality: memory.quality, warnings: memory.warnings
        )
        healthStore = ComputerHealthStore(
            probe: ModulePageUnusedHealthProbe(),
            batterySettingsVerifier: ModulePageInertBatterySettings(),
            batteryPowerModeController: powerModes ?? TestOperationFactory(for: testCase).batteryPowerModeController()
        )
        view = MenuBarAdvancedStatusView(
            store: store,
            computerHealthStore: healthStore,
            panelSettingsState: MenuBarPanelSettingsState(initialDensity: density, defaults: defaults),
            presentation: density,
            initialSection: section,
            fanControl: FanControlCoordinator(
                defaults: defaults,
                helperStatusOverride: .unavailable,
                requestSender: { _ in throw CancellationError() }
            )
        )
    }

    func tearDown() {
        TestPreferenceDomain.cleanup(suiteName: suiteName)
    }

    /// The demo history, moved from the demo's reference date to now, as the
    /// page's prepared display windows.
    func loadDemoHistory() async throws {
        let offset = Date().timeIntervalSince(MiniWindowDemoData.referenceDate)
        let encoded = try JSONEncoder().encode(MiniWindowDemoData.fixture.telemetry)
        var points = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for index in points.indices {
            for key in ["date", "sensorSampledAt", "gpuSampledAt"] {
                if let value = points[index][key] as? Double { points[index][key] = value + offset }
            }
        }
        let shifted = try JSONDecoder().decode([MenuBarTelemetryPoint].self,
                                               from: JSONSerialization.data(withJSONObject: points))
        let monitor = store.menuBarMonitorState
        monitor.restoreHistory(shifted)
        monitor.setDisplayHistoryDemand(view.historyDemandPlan.durations)
        for _ in 0..<400 where monitor.displayTelemetryVersion == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(monitor.displayTelemetryVersion, 0, "the display windows were prepared")
    }

    func render(mode: MiniWindowVisualMode) throws -> NSBitmapImageRep {
        let content = view.geekSelectedDetailPage
            .frame(width: GeekPanelPresentationMetrics.detailWidth(for: section))
            .fixedSize(horizontal: false, vertical: true)
            .metricPanelShell()
            .environment(\.controlPaletteCoordinator, nil)
            .environment(\.menuBarChartsPreparedInline, true)
            .modifier(PanelAppearanceEnvironment(forcedVisualMode: mode))
            .environment(\.displayScale, 2)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// Night is black, day is graphite (D44, D56).
    func exportBothModes(name: String, first night: NSBitmapImageRep) throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_ISTAT_LAYOUT_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (bitmap, suffix) in [(night, "night"), (try render(mode: .graphite), "day")] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}

/// Opens and reads nothing: the power page's open task verifies battery
/// settings, which would read this Mac's battery.
@MainActor
private final class ModulePageInertBatterySettings: BatterySettingsVerifying {
    func beginAdjustment() async -> BatterySettingsBeginResult { .baselineUnavailable }
    func verifyAfterSettingsChange() async -> BatterySettingsVerificationResult { .unverifiable }
    func openSettingsWithoutVerification() -> Bool { false }
    func cancelVerification() {}
}

/// The demo energy modes for the power page; a change is refused (the page
/// is only rendered).
private struct ModulePageDemoPowerModes: BatteryPowerModeControlling {
    func readPowerModes() async -> BatteryPowerModes? {
        MiniWindowDemoData.hardwareControlProfile.powerModes
    }

    func changePowerMode(source _: BatteryPowerSource, mode _: BatteryPowerMode) async -> BatteryPowerModeChangeResult {
        .unsupported
    }
}

private struct ModulePageUnusedHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        throw CancellationError()
    }
}
#endif
