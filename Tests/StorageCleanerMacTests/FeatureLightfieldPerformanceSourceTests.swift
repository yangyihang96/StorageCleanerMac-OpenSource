import Foundation
import XCTest
@testable import StorageCleanerMac

final class FeatureLightfieldPerformanceSourceTests: XCTestCase {
    func testBenchmarkEntryUsesApprovedV11WhileLegacyHistoryKeepsItsRenderer() throws {
        let source = try text("Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkWorkspaceView.swift")
        XCTAssertTrue(source.contains("showsLanding || (selectedRecord == nil && displayedResult?.mSeriesV11 == nil)"),
            "D72/current approved landing must not be bypassed by an automatically loaded legacy result")
        XCTAssertTrue(source.contains("PerformanceBenchmarkLandingView("))
        XCTAssertTrue(source.contains("PerformanceBenchmarkV11ResultPage("))
        XCTAssertTrue(source.contains("PerformanceBenchmarkLegacyResultPage(result: result"))
        XCTAssertFalse(source.contains("PerformanceBenchmarkPageChrome {"), "D77 includes explicitly selected older records")
        XCTAssertTrue(source.contains("usesCompactResultContainer: true"))
        let dashboard = try text("Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7DashboardView.swift")
        XCTAssertTrue(dashboard.contains("if usesCompactResultContainer, let result = latestResult"))
        XCTAssertTrue(dashboard.contains("MSeriesRawResultView(result: raw)"), "Preserve the original raw renderer and protocol evidence")
        XCTAssertTrue(dashboard.contains("historyDetails(result)"))
    }
    func testCompletedMemoryRouteOptsIntoResultsWithoutChangingTheLandingFixture() throws {
        let utilities = try text("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        XCTAssertTrue(utilities.contains("showsResultsWhenSampled: true"), "D77 completed production sample must expose the list")
        let memory = try text("Sources/StorageCleanerMac/Views/LightfieldMemoryPage.swift")
        XCTAssertTrue(memory.contains("showsResultsWhenSampled && snapshot != nil && !requestedPressurePreview"))
        XCTAssertTrue(memory.contains("requestedPressurePreview = true"), "Pressure preview remains an explicit alternate view")
        XCTAssertTrue(memory.contains("initiallyExpanded: false"), "D77 ten-row budget excludes automatic child expansion")
    }
    func testProductionPagesReuseB2AndDoNotAddContainersOrDecoration() throws {
        for file in ["LightfieldMemoryPage.swift", "LightfieldEnergyPage.swift", "LightfieldStartupLandingView.swift"] {
            let source = try text("Sources/StorageCleanerMac/Views/" + file)
            for forbidden in ["Material", ".glassPanel", ".glassEffect", "SurfaceCard", "Color(hex:", "0x", "Image(systemName:"] {
                XCTAssertFalse(source.contains(forbidden), file + " " + forbidden)
            }
            XCTAssertTrue(source.contains("FeatureLightfieldPage("), file)
        }
        let memory = try text("Sources/StorageCleanerMac/Views/LightfieldMemoryPage.swift")
        for component in ["LightfieldRing(", "LightfieldMetricGroup(", "LightfieldTrendChart(", "LightfieldSummary(",
            "LightfieldAppIcon(", "LightfieldStatusGlyph(", "LightfieldExpandableRow(", "LightfieldDataBar("] {
            XCTAssertTrue(memory.contains(component), component)
        }
        XCTAssertTrue(memory.contains("progress: display?.measuredUsedRatio,"), "Unknown occupancy is never a measured zero")
        let common = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfield.swift")
        XCTAssertTrue(common.contains("performancePages: [ReviewFilter] = [.startup, .memory, .energy]"))
        XCTAssertTrue(common.contains("pilots.contains(module) || performancePages.contains(module)"))
        let startup = try text("Sources/StorageCleanerMac/Views/LightfieldStartupLandingView.swift")
        for icon in [".startupLogin", ".startupBackground", ".startupStartupAgent"] { XCTAssertTrue(startup.contains(icon)) }
        XCTAssertFalse(startup.contains("selection:"), "No new startup scan-scope semantics")
    }
    func testPIDsAreTooltipOnlyAndSnapshotChildrenKeepTheirRealIdentity() throws {
        let memory = try text("Sources/StorageCleanerMac/Views/LightfieldMemoryPage.swift")
        let energy = try text("Sources/StorageCleanerMac/Views/LightfieldEnergyPage.swift")
        XCTAssertFalse(memory.contains("Text(String(process.id))"))
        XCTAssertFalse(energy.contains("Text(String(id))"))
        XCTAssertTrue(memory.contains(".help(LightfieldPerformancePresentation.processHelp(id: process.id"))
        XCTAssertTrue(energy.contains(".help(LightfieldPerformancePresentation.processHelp(id: id"))
        XCTAssertTrue(memory.contains("processIdentifier: process.id"))
        // D70⑥/fix3: the same identity guards now run inside one detached batch,
        // with a reused reader; the View only publishes an uncancelled result.
        XCTAssertTrue(energy.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(energy.contains("var reader = makeReader()"))
        XCTAssertTrue(energy.contains("reader.path(of: id)"))
        XCTAssertFalse(energy.contains("EnergyImpactService.executablePath(processIdentifier: id)"))
        XCTAssertTrue(energy.contains("withTaskCancellationHandler"))
        XCTAssertTrue(energy.contains("guard !Task.isCancelled else { return }"))
        XCTAssertTrue(energy.contains("guard namingRequest.expanded, !Task.isCancelled else { return }"))
        XCTAssertTrue(energy.contains("LightfieldAppIcon(path: children[id]?.bundlePath"))
        XCTAssertTrue(energy.contains("path.hasPrefix(bundle + \"/\")"), "A reused PID cannot inherit an unrelated app name")
        XCTAssertTrue(energy.contains("guard path == app.path else { continue }"))
        let components = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift")
        XCTAssertTrue(components.contains("NSRunningApplication(processIdentifier: processIdentifier)"))
        XCTAssertTrue(components.contains("bundle == path || bundle.hasPrefix(path + \"/\")"))
        XCTAssertTrue(components.contains("Image(systemName: \"gearshape.fill\")"), "Daemons share the B2 grey placeholder")
    }
    func testPowerMetricsRetainTheirVisibilityDemandOwnerAndUnknownEvidence() throws {
        let helper = try text("Sources/StorageCleanerMac/Views/HelperPowerMetricsView.swift")
        XCTAssertTrue(helper.contains("monitor.updateConsumer(consumerID, visible: visible && permitsLiveDemand)"))
        XCTAssertTrue(helper.contains(".onDisappear { monitor.updateConsumer(consumerID, visible: false) }"))
        XCTAssertTrue(helper.contains("window?.occlusionState.contains(.visible) == true"))
        XCTAssertTrue(helper.contains("HelperPowerMetricsPresentation.rows(monitor.state, now: context.date)"))
        let energy = try text("Sources/StorageCleanerMac/Views/LightfieldEnergyPage.swift")
        XCTAssertTrue(energy.contains("app.currentEvidence.source == .unknown ? \"—\""))
        XCTAssertTrue(energy.contains("app.averageEvidence.source == .unknown ? \"—\""))
        XCTAssertTrue(energy.contains("snapshot.apps.allSatisfy({ $0.currentEvidence.source != .unknown })"))
        for forbidden in ["updateConsumer(", "readPowerMetrics(", "Process(", "requestQuit", "terminate("] {
            XCTAssertFalse(energy.contains(forbidden), forbidden)
        }
        let memory = try text("Sources/StorageCleanerMac/Views/LightfieldMemoryPage.swift")
        XCTAssertTrue(memory.contains("store.requestQuitSelectedMemoryProcesses()"), "Reuse existing confirmation")
        XCTAssertFalse(memory.contains("store.optimizeMemory("))
        XCTAssertFalse(memory.contains("store.requestQuitProcess("), "No new per-process exit action")
        XCTAssertTrue(memory.contains("最新进程快照："))
        XCTAssertFalse(memory.contains("该时刻占用最多"), "History has no historical process attribution")
    }
    func testFixturesAndReferencesAreStrictlyDebugOnly() throws {
        let fixture = try text("Sources/StorageCleanerMac/Debug/LightfieldPerformanceFixture.swift")
        XCTAssertTrue(fixture.hasPrefix("#if DEBUG\n"))
        XCTAssertTrue(fixture.hasSuffix("#endif\n"))
        for forbidden in ["FileManager.", "Process()", "refreshMemory(", "requestQuit", "updateConsumer(", "NSWorkspace."] {
            XCTAssertFalse(fixture.contains(forbidden), forbidden)
        }
        for file in ["Debug/FeaturePresentationDemo.swift", "Debug/FeatureLightfieldResultFixture.swift", "Views/LightfieldEnergyPage.swift"] {
            var conditions: [String] = []
            for line in try text("Sources/StorageCleanerMac/" + file).components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if ") { conditions.append(String(trimmed.dropFirst(4))); continue }
                if trimmed == "#endif" { XCTAssertFalse(conditions.isEmpty); if !conditions.isEmpty { conditions.removeLast() }; continue }
                if trimmed == "#else", !conditions.isEmpty { conditions[conditions.count - 1] = "else"; continue }
                if line.contains("LightfieldPerformanceFixture") { XCTAssertTrue(conditions.contains("DEBUG"), file + " " + line) }
            }
            XCTAssertTrue(conditions.isEmpty, file)
        }
    }
    func testReadableNamesDoNotInventRolesOrPrintThePID() {
        let renderer = LightfieldPerformancePresentation.processName(name: "Browser Helper (Renderer)", path: "/Fixture/Renderer", application: "浏览器")
        XCTAssertEqual(renderer, L10n.text("浏览器 · 网页渲染", "浏览器 · Web Renderer"))
        XCTAssertEqual(LightfieldPerformancePresentation.processName(name: "unknown-worker", path: "/usr/libexec/unknown-worker", application: "浏览器"), "unknown-worker")
        XCTAssertEqual(LightfieldPerformancePresentation.processName(name: "worker", path: "/Applications/GPU Helper.app/Contents/MacOS/worker", application: "浏览器"), "worker")
        XCTAssertEqual(LightfieldPerformancePresentation.processName(name: "", path: "", application: "浏览器"), L10n.text("名称不可用", "Name Unavailable"))
        XCTAssertTrue(LightfieldPerformancePresentation.processHelp(id: 12345, path: "/Fixture").contains("12345"))
        XCTAssertFalse(renderer.contains("12345"))
    }
    private func text(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
