#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Independent acceptance bounds from the 2026-10-11 feedback / D77.
/// Existing production matrices retain the updater/file-page contracts.
@MainActor
func assertCompactResultSkeleton(_ frames: [String: CGRect], window: CGSize,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
    let viewport = try XCTUnwrap(frames["fixture.viewport"], file: file, line: line)
    let content = try XCTUnwrap(frames["lightfield.content"], file: file, line: line)
    let primary = try XCTUnwrap(frames["lightfield.primary"], file: file, line: line)
    let status = try XCTUnwrap(frames["lightfield.status"], file: file, line: line)
    let title = try XCTUnwrap(frames["lightfield.title"], file: file, line: line)
    for rect in [content, primary, status, title] {
        XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(rect), file: file, line: line)
    }
    XCTAssertLessThanOrEqual(title.maxY, 72, file: file, line: line)
    XCTAssertEqual(content.minY, 72, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(content.width, viewport.width - (viewport.width < 600 ? 32 : 48), accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(status.height, 48, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(status.maxY, viewport.maxY, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(primary.height, 32, accuracy: 0.5, file: file, line: line)
    XCTAssertTrue(status.insetBy(dx: -0.5, dy: -0.5).contains(primary), file: file, line: line)
    XCTAssertEqual(status.minY - content.maxY, 8, accuracy: 0.5, file: file, line: line)
    XCTAssertFalse(content.intersects(primary), file: file, line: line)
    if window == CGSize(width: 1280, height: 763) {
        XCTAssertEqual(content, CGRect(x: 24, y: 72, width: 1022, height: 607), file: file, line: line)
        XCTAssertEqual(primary, CGRect(x: 846, y: 695, width: 200, height: 32), file: file, line: line)
        XCTAssertEqual(status, CGRect(x: 24, y: 687, width: 1022, height: 48), file: file, line: line)
        XCTAssertEqual(title.origin, CGPoint(x: 80, y: 18), file: file, line: line)
    }
}

@MainActor
final class FeatureLightfieldResultSpaceTests: XCTestCase {
    func testResultBudgetGrowsWithWindowAndNeverRendersLandingArtwork() async throws {
        let modules: [ReviewFilter] = [.green, .healthHub, .privacy, .performance, .startup, .memory, .energy, .uninstall]
        for module in modules {
            XCTAssertTrue(FeatureLightfield.usesResultSpace(module))
            let root = FeatureLightfieldPage(module: module, phase: .result, title: module.sidebarTitle,
                status: "Result", safety: "Read only", actionTitle: "Review", action: {}) {
                LightfieldResultContent {
                    LightfieldSummary(module: module, label: "Items", value: "40", unit: "")
                } rows: {
                    ForEach(0..<40, id: \.self) { index in
                        Text("Item \(index)").frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 52).layoutProbe("acceptance.row.\(index)")
                    }
                }
            }.environment(\.featureDisablesLayoutAnimations, true)
            let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1070, height: 735), dark: true)
            defer { host.close() }
            var previousHeight: CGFloat = 0
            for window in [CGSize(width: 1280, height: 763), CGSize(width: 1680, height: 1050), CGSize(width: 2400, height: 1350)] {
                let size = CGSize(width: window.width - 210, height: window.height - 28)
                host.resize(to: size)
                let frames = try await host.frames(required: ["fixture.viewport", "lightfield.title", "lightfield.content",
                    "lightfield.primary", "lightfield.status", "lightfield.artwork", "lightfield.results.scrollViewport"], size: size)
                try assertCompactResultSkeleton(frames, window: window)
                let art = try XCTUnwrap(frames["lightfield.artwork"])
                let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
                let content = try XCTUnwrap(frames["lightfield.content"])
                XCTAssertEqual(viewport.minX, content.minX, accuracy: 0.5)
                XCTAssertEqual(viewport.maxX, content.maxX, accuracy: 0.5)
                XCTAssertEqual(viewport.minY, content.minY, accuracy: 0.5)
                XCTAssertEqual(viewport.maxY, content.maxY, accuracy: 0.5)
                XCTAssertEqual(viewport.height, content.height, accuracy: 0.5,
                    "The actual scroll viewport must fill the content, not just fit ten rows")
                XCTAssertLessThanOrEqual(art.width, 48)
                XCTAssertLessThanOrEqual(art.maxY, 72)
                XCTAssertFalse(art.intersects(viewport))
                XCTAssertGreaterThan(viewport.height, previousHeight)
                previousHeight = viewport.height
                XCTAssertGreaterThanOrEqual(fullyVisibleRows(frames, prefix: "acceptance.row.", viewport: viewport), 10, module.rawValue)
            }
        }
        for module in [ReviewFilter.updater, .largeFiles, .duplicates] {
            XCTAssertFalse(FeatureLightfield.usesResultSpace(module), "Parallel batches retain their layout contract")
        }
    }

    func testProductionUninstallAndStartupShowTenCompleteRowsThenMoreOnEnlargement() async throws {
        let first = try XCTUnwrap(MainWindowSnapshotPipeline.startupItemsFixture.first)
        let items = (0..<40).map { index in
            StartupItemsDomain.Item(id: "space-startup-\(index)", kind: first.kind, scope: first.scope,
                name: "Startup \(index)", components: first.components, state: first.state,
                attribution: nil, actionCapability: first.actionCapability, warnings: [])
        }
        let startup = StartupItemsDashboardView(items: items, isLoading: false, progress: nil,
            coverageAction: AnyView(EmptyView()), onRefresh: {}, onCancel: {})
            .defaultAppStorage(TestPreferenceDomain.make(for: self))
        let uninstall = FeatureLightfieldResultFixture(module: .uninstall)
        for (view, prefix) in [(AnyView(startup), "startup.row."), (AnyView(uninstall), "lightfield.uninstall.row.")] {
            let host = CalibrationAppKitLayoutHost(root: view.environment(\.featureDisablesLayoutAnimations, true)
                .environment(\.featurePresentationIsFixture, true), size: .init(width: 1070, height: 735), dark: false)
            defer { host.close() }
            var previousCount = 0
            for size in [CGSize(width: 1070, height: 735), CGSize(width: 1470, height: 1022)] {
                host.resize(to: size)
                let frames = try await host.frames(required: ["lightfield.results.scrollViewport", "fixture.viewport"], size: size)
                let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
                let count = fullyVisibleRows(frames, prefix: prefix, viewport: viewport)
                XCTAssertGreaterThanOrEqual(count, 10, prefix)
                XCTAssertGreaterThan(count, previousCount, "Enlarging the window must expose more actual rows")
                previousCount = count
            }
        }
    }

    func testProductionEnergyShowsTenCollapsedRowsWithoutStartingChildReads() async throws {
        let original = try XCTUnwrap(LightfieldPerformanceFixture.energy.apps.first)
        let apps = (0..<40).map { index in
            EnergyImpactApp(id: "space-energy-\(index)", name: "Energy \(index)", path: original.path,
                iconPath: original.iconPath, bundlePath: original.bundlePath, bundleIdentifier: original.bundleIdentifier,
                measuredEnergyWh: original.measuredEnergyWh, estimatedSupplementEnergyWh: 0,
                estimatedEnergyWh: original.estimatedEnergyWh, currentPowerWatts: original.currentPowerWatts,
                averagePowerWatts: original.averagePowerWatts, cpuPercent: 1, diskReadBytesPerSecond: 0,
                diskWriteBytesPerSecond: 0, residentBytes: 0, cumulativeCPUSeconds: 1, longestRunningSeconds: 60,
                processCount: 4, measuredProcessCount: 4, processIDs: original.processIDs, isApplication: true,
                currentMeasuredProcessCount: 4, sampledAt: original.sampledAt, currentSampleSeconds: 1)
        }
        let snapshot = EnergyImpactSnapshot(generatedAt: LightfieldPerformanceFixture.date, scanSeconds: 3,
            sampleSeconds: 1, uptimeSeconds: 60, apps: apps, processCount: 160, measuredProcessCount: 160,
            unmeasuredProcessCount: 0, measuredTotalEnergyWh: 1, estimatedSupplementEnergyWh: 0,
            calibrationWattsPerCore: 2, usesLocalCalibration: true)
        let root = LightfieldEnergyPage(snapshot: snapshot, searchText: .constant(""), sortMode: .constant(.name),
            canRefresh: true, refresh: {}) { EmptyView() }
            .environment(\.featurePresentationIsFixture, true).environment(\.featureDisablesLayoutAnimations, true)
        let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1070, height: 735), dark: false)
        defer { host.close() }
        let frames = try await host.frames(required: ["lightfield.results.scrollViewport", "fixture.viewport"], size: .init(width: 1070, height: 735))
        let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
        XCTAssertGreaterThanOrEqual(fullyVisibleRows(frames, prefix: "energy.row.", viewport: viewport), 10)
        XCTAssertFalse(frames.keys.contains { $0.hasPrefix("energy.child.") })
    }

    func testCleanupScopesHaveFourDistinctDecodedIconsBetweenCheckAndTwoTextLines() async throws {
        let art = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Art")
        let library = GeneratedArtLibrary(resolver: .lightfieldOptionsDirectory(art))
        let root = VStack(spacing: 0) {
            ForEach(SafeCleanupScanScope.allCases, id: \.self) { scope in
                FeatureLightfieldCleanupScopeRow(scope: scope, selected: true, onToggle: {}, iconLibrary: library)
            }
        }.frame(width: 520).frame(maxHeight: .infinity, alignment: .top)
            .environment(\.featureDisablesLayoutAnimations, true)
        let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 520, height: 300), dark: false)
        defer { host.close() }
        let stems = SafeCleanupScanScope.allCases.map(FeatureLightfieldCleanupScopeRow.resourceStem)
        XCTAssertEqual(Set(stems).count, 4)
        for scope in SafeCleanupScanScope.allCases {
            let stem = FeatureLightfieldCleanupScopeRow.resourceStem(scope), prefix = "lightfield.cleanup.scope." + stem
            for size in [192, 512] {
                let loaded = await library.image(named: stem + "-\(size)")
                let picture = try XCTUnwrap(loaded)
                XCTAssertEqual(picture.width, size)
                XCTAssertEqual(picture.height, size)
                XCTAssertTrue([CGImageAlphaInfo.premultipliedFirst, .premultipliedLast, .first, .last].contains(picture.alphaInfo))
            }
            let ids = Set(["check", "icon", "title", "detail"].map { prefix + "." + $0 })
                .union(["lightfield.option.loaded." + stem + "-192"])
            let frames = try await host.frames(required: ids,
                size: .init(width: 520, height: 300))
            let check = try XCTUnwrap(frames[prefix + ".check"]), icon = try XCTUnwrap(frames[prefix + ".icon"])
            let title = try XCTUnwrap(frames[prefix + ".title"]), detail = try XCTUnwrap(frames[prefix + ".detail"])
            XCTAssertEqual(icon.size, CGSize(width: 40, height: 40))
            XCTAssertGreaterThan(try XCTUnwrap(frames["lightfield.option.loaded." + stem + "-192"]).height, 0,
                "The bitmap must be drawn; an empty reserved slot is insufficient")
            XCTAssertLessThan(check.maxX, icon.minX)
            XCTAssertLessThan(icon.maxX, title.minX)
            XCTAssertLessThan(title.maxY, detail.minY)
            try await host.waitForAccessibility(labels: [FeatureLightfieldCleanupScopeRow.title(scope)], pressLabels: [FeatureLightfieldCleanupScopeRow.title(scope)])
        }
    }

    func testCompactPrimaryHasThirtyTwoPointVisualAndFortyFourPointNativeTarget() async throws {
        for module in [ReviewFilter.green, .healthHub, .privacy, .performance, .startup, .memory, .energy, .uninstall] {
            var presses = 0
            let label = "Review " + module.rawValue
            let root = FeatureLightfieldPage(module: module, phase: .result, title: module.sidebarTitle,
                status: "Read only", safety: "Review first", actionTitle: label, action: { presses += 1 }) {
                    Text("Results")
                }.environment(\.featureDisablesLayoutAnimations, true)
            let size = CGSize(width: 1070, height: 735)
            let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: false)
            defer { host.close() }
            let frames = try await host.frames(required: ["lightfield.primary", "lightfield.primary.hitTarget",
                "lightfield.status", "lightfield.content", "fixture.viewport"], size: size)
            let visual = try XCTUnwrap(frames["lightfield.primary"])
            let target = try XCTUnwrap(frames["lightfield.primary.hitTarget"])
            XCTAssertEqual(visual.height, 32, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(target.height, 44)
            XCTAssertTrue(try XCTUnwrap(frames["lightfield.status"]).insetBy(dx: -0.5, dy: -0.5).contains(target))
            XCTAssertFalse(target.intersects(try XCTUnwrap(frames["lightfield.content"])))
            try await host.waitForAccessibility(labels: [label], pressLabels: [label],
                hitTestFrames: [target], hitTestViewport: try XCTUnwrap(frames["fixture.viewport"]))
            let native = try host.accessibilityFrame(label: label)
            XCTAssertEqual(native.minY, target.minY, accuracy: 0.5)
            XCTAssertEqual(native.height, target.height, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(native.height, 44)
            XCTAssertTrue(try host.press(label: label))
            XCTAssertEqual(presses, 1)
        }
    }

    func testEnergyFirstAppIdentityDoesNotInheritExpansionAfterFilteringOrSorting() async throws {
        let model = ResultSpaceEnergyModel()
        let apps = LightfieldPerformanceFixture.energy.apps
        let first = try XCTUnwrap(apps.first)
        let replacement = try XCTUnwrap(apps.first { $0.processIDs.count > 1 && $0.id != first.id })
        let size = CGSize(width: 1070, height: 735)
        let root = ResultSpaceEnergyFixture(model: model)
            .environment(\.featurePresentationIsFixture, true).environment(\.featureDisablesLayoutAnimations, true)
        let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: false)
        defer { host.close() }
        let initial = try await host.frames(required: ["energy.row." + first.id, "lightfield.results.scrollViewport"], size: size)
        try await host.waitForAccessibility(labels: [first.name], expectedValues: [first.name: L10n.text("已折叠", "Collapsed")],
            pressLabels: [first.name], hitTestFrames: [try XCTUnwrap(initial["energy.row." + first.id])])
        XCTAssertTrue(try host.press(label: first.name))
        // Invalidate retained native hit objects after each structural change.
        // Same-size layout preserves the production view's SwiftUI identity
        // and state, but reacquires AX nodes for the current rendered buttons.
        host.resize(to: size)
        let more = L10n.text("再显示 \(first.processIDs.count - 1) 个", "Show \(first.processIDs.count - 1) More")
        let expanded = try await host.frames(required: ["energy.app." + first.id + ".more"], size: size)
        try await host.waitForAccessibility(labels: [first.name, more],
            expectedValues: [first.name: L10n.text("已展开", "Expanded")], pressLabels: [first.name, more],
            hitTestFrames: [try XCTUnwrap(expanded["energy.row." + first.id]),
                try XCTUnwrap(expanded["energy.app." + first.id + ".more"])],
            hitTestViewport: try XCTUnwrap(initial["lightfield.results.scrollViewport"]))
        XCTAssertTrue(try host.press(label: more))
        _ = try await host.frames(required: Set(first.processIDs.map { "energy.child.text.\($0)" }), size: size)

        model.query = replacement.name
        host.resize(to: size)
        let changed = try await host.frames(required: ["energy.row." + replacement.id], size: size)
        try await host.waitForAccessibility(labels: [replacement.name],
            expectedValues: [replacement.name: L10n.text("已折叠", "Collapsed")], pressLabels: [replacement.name],
            hitTestFrames: [try XCTUnwrap(changed["energy.row." + replacement.id])],
            hitTestViewport: try XCTUnwrap(initial["lightfield.results.scrollViewport"]))
        XCTAssertFalse(changed.keys.contains { $0.hasPrefix("energy.child.text.") }, "New first app must not parse or draw children")
        XCTAssertTrue(try host.press(label: replacement.name))
        let oneChild = try await host.frames(required: ["energy.child.text.\(replacement.processIDs[0])"], size: size)
        XCTAssertNil(oneChild["energy.child.text.\(replacement.processIDs[1])"], "Show-all state must not migrate with a header slot")

        model.query = ""
        model.sort = .name
        host.resize(to: size)
        let sortedFirst = try XCTUnwrap(EnergyImpactListPresenter.presentation(apps: apps, query: "", sortMode: .name).apps.first)
        let sorted = try await host.frames(required: ["energy.row." + sortedFirst.id], size: size)
        try await host.waitForAccessibility(labels: [sortedFirst.name],
            expectedValues: [sortedFirst.name: L10n.text("已折叠", "Collapsed")], pressLabels: [sortedFirst.name],
            hitTestFrames: [try XCTUnwrap(sorted["energy.row." + sortedFirst.id])],
            hitTestViewport: try XCTUnwrap(initial["lightfield.results.scrollViewport"]))
    }

    func testProductionMemoryOverviewRendererStaysVisibleWithCompleteNativeValues() async throws {
        let used = "12.75 GB / 16 GB"
        let root = FeatureLightfieldPage(module: .memory, phase: .result, title: ReviewFilter.memory.sidebarTitle,
            status: "Sampled", safety: "Normal quit", actionTitle: "Refresh", action: {}) {
            GeometryReader { proxy in
                LightfieldResultContent {
                    LightfieldMemoryResultOverview(usedAndTotal: used,
                        secondary: [.init(id: "cache", label: "Cache", value: "512 MB"),
                            .init(id: "swap", label: "Swap", value: "0 B"),
                            .init(id: "selection", label: "Estimated Release", value: "3.25", unit: "GB")],
                        contentWidth: proxy.size.width, note: "Pressure normal")
                } rows: {
                    ForEach(0..<40, id: \.self) { row in
                        Text("Process \(row)").frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 48).layoutProbe("overview.process.\(row)")
                    }
                }
            }
        }.environment(\.featureDisablesLayoutAnimations, true)
        let size = CGSize(width: 1070, height: 735)
        let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: false)
        defer { host.close() }
        for size in [size, CGSize(width: 613, height: 338), CGSize(width: 467, height: 362)] {
            host.resize(to: size)
            let frames = try await host.frames(required: ["lightfield.memory.overview", "lightfield.results.scrollViewport",
                "lightfield.content"], size: size)
            let overview = try XCTUnwrap(frames["lightfield.memory.overview"])
            XCTAssertGreaterThan(overview.width, 0)
            XCTAssertGreaterThan(overview.height, 0)
            XCTAssertLessThanOrEqual(overview.maxY, 72)
            XCTAssertEqual(try XCTUnwrap(frames["lightfield.results.scrollViewport"]), try XCTUnwrap(frames["lightfield.content"]))
            let label = L10n.text("内存总览 · 已用 / 总量", "Memory Overview · Used / Total") + " · " + used
            try await host.waitForAccessibility(labels: [label])
            if size.width == 1070 {
                XCTAssertGreaterThanOrEqual(fullyVisibleRows(frames, prefix: "overview.process.",
                    viewport: try XCTUnwrap(frames["lightfield.results.scrollViewport"])), 10)
                try await host.waitForAccessibility(labels: ["Cache · 512 MB", "Swap · 0 B", "Estimated Release · 3.25 GB"])
            }
        }
    }

    func testLegacyHistoryUsesFullResultContainerAndOriginalRawComponents() async throws {
        for version in ["synthetic-v9", "synthetic-v10"] {
            let original = MSeriesV11TestFixtures.result()
            var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            var versions = try XCTUnwrap(encoded["versions"] as? [String: Any])
            versions["planVersion"] = version
            encoded["versions"] = versions
            let result = try JSONDecoder().decode(BenchmarkV7Result.self, from: JSONSerialization.data(withJSONObject: encoded))
            XCTAssertNil(result.mSeriesV11)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let frozen = try encoder.encode(result)
            let leaderboard = BenchmarkV7LeaderboardStore(service: UnavailableBenchmarkV7LeaderboardService(),
                identityProvider: ResultSpaceBenchmarkIdentity())
            let root = PerformanceBenchmarkLegacyResultPage(result: result, canStart: false,
                onStart: { XCTFail("Layout inspection cannot start a benchmark") }) {
                BenchmarkV7DashboardView(state: .idle, latestResult: result, history: [result], localBestResult: nil,
                    localBestResultsByCategory: [:], currentScoringVersion: "different-current-protocol",
                    historyStatus: .missing, leaderboardStore: leaderboard, preflight: nil, isPreflighting: false,
                    canStart: false, explanation: nil, onStart: { XCTFail("No workload") }, onCancel: { XCTFail("No cancellation") },
                    onDeleteHistoryRecord: { _ in XCTFail("No history writes") }, onExportHistoryRecord: { _ in nil },
                    usesCompactResultContainer: true)
            }.environment(\.featureDisablesLayoutAnimations, true).environment(\.moduleTheme, ReviewFilter.performance.moduleTheme)
            let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1070, height: 735), dark: false)
            defer { host.close() }
            for size in [CGSize(width: 1070, height: 735), CGSize(width: 467, height: 362), CGSize(width: 1470, height: 1022)] {
                host.resize(to: size)
                let frames = try await host.frames(required: ["lightfield.content", "lightfield.results.scrollViewport",
                    "lightfield.artwork", "lightfield.title", "lightfield.primary", "lightfield.status",
                    "fixture.viewport", "benchmark.legacy.result", "benchmark.legacy.raw"], size: size)
                try assertCompactResultSkeleton(frames, window: .init(width: size.width + 210, height: size.height + 28))
                XCTAssertEqual(try XCTUnwrap(frames["lightfield.results.scrollViewport"]), try XCTUnwrap(frames["lightfield.content"]))
                XCTAssertLessThanOrEqual(try XCTUnwrap(frames["lightfield.artwork"]).width, 48)
                XCTAssertNil(frames["benchmark.persistentActions"], "Legacy result must not recreate the old action/monitor chrome")
                XCTAssertNil(frames["benchmark.monitor"])
                XCTAssertGreaterThan(try XCTUnwrap(frames["benchmark.legacy.raw"]).height, 0)
                XCTAssertEqual(result.versions.planVersion, version)
                XCTAssertEqual(try encoder.encode(result), frozen, "Presentation cannot reinterpret archived evidence")
            }
        }
    }

    func testAnimatedPhaseSwapsPublishExactlyOneStateLayerAndNoStaleText() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: project.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfield.swift"), encoding: .utf8)
        let start = try XCTUnwrap(shell.range(of: "struct FeatureLightfieldPage<Content: View>")).lowerBound
        let end = try XCTUnwrap(shell.range(of: "private struct FeatureLightfieldFloat:", range: start..<shell.endIndex)).lowerBound
        let page = String(shell[start..<end])
        XCTAssertTrue(page.contains(".transition(.identity)\n                    .lightfieldFrame(geometry.content"),
            "A phase identity cannot retain the outgoing content with opacity/offset")
        XCTAssertTrue(page.contains("$0.animation = nil"), "The page clears inherited phase animations")
        for suffix in page.components(separatedBy: ".animation(").dropFirst() {
            var depth = 1
            var expression = ""
            for character in suffix {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth == 0 { break }
                expression.append(character)
            }
            XCTAssertNil(expression.range(of: #"value\s*:\s*phase\b"#, options: .regularExpression),
                "The phase host must not reintroduce a parent animation")
        }
        let parent = try String(contentsOf: project.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/DesignSystem/FeatureTemplates.swift"), encoding: .utf8)
        XCTAssertTrue(parent.contains(".animation(lightfieldModule != nil\n                ? nil"),
            "The actual parent also declines phase animation for Lightfield routes")
        let model = ResultSpacePhaseModel(), capture = ResultSpaceLayerCapture()
        let root = ResultSpacePhaseFixture(model: model).onPreferenceChange(FeatureLightfieldStateLayersKey.self) { layers in
            Task { @MainActor in capture.values.append(layers) }
        }
        .featureFlowTransition(value: model.phase)
        .environment(\.featureLightfieldModule, .uninstall)
        .environment(\.featureDisablesLayoutAnimations, false)
        let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1070, height: 735), dark: false)
        defer { host.close() }
        for phase in [FeatureLightfieldPhase.landing, .running, .result, .running, .result] {
            withAnimation(.easeInOut(duration: 0.9)) { model.phase = phase }
            // Observe the entire outgoing transition interval. Waiting only
            // for the final layout would conceal a retained old state layer.
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertTrue(capture.values.allSatisfy { $0.values.reduce(0, +) == 1 })
            }
            let frames = try await host.frames(required: ["space.phase." + phase.rawValue, "lightfield.content"], size: .init(width: 1070, height: 735))
            for other in FeatureLightfieldPhase.allCases where other != phase { XCTAssertNil(frames["space.phase." + other.rawValue]) }
            XCTAssertEqual(capture.values.last, [phase.rawValue: 1])
        }
        XCTAssertFalse(capture.values.isEmpty)
        XCTAssertTrue(capture.values.allSatisfy { $0.values.reduce(0, +) == 1 })
    }

    func testSnapshotSettleRejectsBusyDuplicateLayersAndChangingGeometryUntilBoundedMotionEnds() {
        let frames = ["lightfield.content": CGRect(x: 24, y: 72, width: 1022, height: 607),
            "lightfield.primary": CGRect(x: 846, y: 695, width: 200, height: 32),
            "lightfield.status": CGRect(x: 24, y: 687, width: 1022, height: 48)]
        var gate = FeatureLightfieldSettleGate()
        XCTAssertFalse(gate.observe(elapsed: 10, busy: true, matchesPage: true, layers: ["result": 1], expectedPhase: .result, frames: frames))
        XCTAssertFalse(gate.observe(elapsed: 10, busy: false, matchesPage: true, layers: ["running": 1, "result": 1], expectedPhase: .result, frames: frames))
        // Invalid layers stay invalid even when geometry is stable and both
        // animation/stability budgets have expired; no intervening reset.
        for elapsed in [10.2, 10.4, 11.5, 20.0] {
            XCTAssertFalse(gate.observe(elapsed: elapsed, busy: false, matchesPage: true,
                layers: ["running": 1, "result": 1], expectedPhase: .result, frames: frames))
        }
        XCTAssertFalse(gate.observe(elapsed: 10, busy: false, matchesPage: false, layers: ["result": 1], expectedPhase: .result, frames: frames))
        XCTAssertFalse(gate.observe(elapsed: 0, busy: false, matchesPage: true, layers: ["result": 1], expectedPhase: .result, frames: frames))
        XCTAssertFalse(gate.observe(elapsed: 0.5, busy: false, matchesPage: true, layers: ["result": 1], expectedPhase: .result, frames: frames))
        var changed = frames
        changed["lightfield.content"]?.size.height -= 10
        XCTAssertFalse(gate.observe(elapsed: 2, busy: false, matchesPage: true, layers: ["result": 1], expectedPhase: .result, frames: changed))
        XCTAssertFalse(gate.observe(elapsed: 2.2, busy: false, matchesPage: true, layers: ["result": 1], expectedPhase: .result, frames: changed))
        XCTAssertTrue(gate.observe(elapsed: 2.4, busy: false, matchesPage: true, layers: ["result": 1], expectedPhase: .result, frames: changed))
        XCTAssertGreaterThanOrEqual(FeatureLightfieldSettleGate.animationBudget, 1.4)
    }

    func testStateLayerPreferenceCountsAllContributingSubtrees() {
        var layers = FeatureLightfieldStateLayersKey.defaultValue
        FeatureLightfieldStateLayersKey.reduce(value: &layers) { ["result": 1] }
        FeatureLightfieldStateLayersKey.reduce(value: &layers) { ["running": 1, "result": 1] }
        XCTAssertEqual(layers, ["result": 2, "running": 1], "Last-writer-wins would conceal a retained subtree")
    }

    func testFooterTextHistoryAndActionsHaveDisjointNativeFrames() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let root = FeatureLightfieldPage(module: .uninstall, phase: .result,
                title: ReviewFilter.uninstall.sidebarTitle, status: String(repeating: "Long status · ", count: 12),
                safety: String(repeating: "Review before moving · ", count: 12), actionTitle: "Review selection",
                statusActionTitle: "Refresh", statusAction: {}, action: {}) { Text("Results") }
                .environment(\.featureOperationHistoryAction, {}).environment(\.featureDisablesLayoutAnimations, true)
            let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1070, height: 735), dark: false)
            defer { host.close() }
            for size in [CGSize(width: 1070, height: 735), CGSize(width: 467, height: 362)] {
                host.resize(to: size)
                let ids: Set<String> = ["fixture.viewport", "lightfield.status", "lightfield.primary",
                    "lightfield.status.history", "lightfield.status.text", "lightfield.status.action"]
                let frames = try await host.frames(required: ids, size: size)
                let footer = try XCTUnwrap(frames["lightfield.status"])
                let action = try XCTUnwrap(frames["lightfield.primary"])
                let parts = try ["history", "text", "action"].map { try XCTUnwrap(frames["lightfield.status." + $0]) }
                XCTAssertGreaterThanOrEqual(parts[0].height, 44, "History remains a usable native target")
                XCTAssertGreaterThanOrEqual(parts[2].height, 44, "Refresh remains a usable native target")
                for part in parts {
                    XCTAssertTrue(footer.insetBy(dx: -0.5, dy: -0.5).contains(part))
                    XCTAssertLessThanOrEqual(part.maxX + 16, action.minX + 0.5)
                }
                XCTAssertLessThanOrEqual(parts[0].maxX, parts[1].minX + 0.5)
                XCTAssertLessThanOrEqual(parts[1].maxX, parts[2].minX + 0.5)
                if size.width >= 740 {
                    let safety = try XCTUnwrap(frames["lightfield.status.safety"])
                    XCTAssertLessThanOrEqual(parts[2].maxX, safety.minX + 0.5)
                    XCTAssertLessThanOrEqual(safety.maxX + 16, action.minX + 0.5)
                }
            }
        }
    }

    func testRuntimeCaptureWaitsForObservedSettleAndReportsTimeoutTruthfully() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Debug/MainWindowSnapshotPipeline.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("let settled = active ? false : await waitForSettledFeature(filter, busy: busy)"))
        XCTAssertTrue(source.contains("let suffix = active ? \"active\" : settled ? \"settled\" : \"unsettled\""))
        XCTAssertTrue(source.contains("\"settleEvidence\": FeatureLightfieldResultAudit.capture"))
        XCTAssertTrue(source.contains("frames[\"lightfield.canvas\"]?.origin"))
        XCTAssertTrue(source.contains("gate.observe("))
    }

    private func fullyVisibleRows(_ frames: [String: CGRect], prefix: String, viewport: CGRect) -> Int {
        frames.filter { $0.key.hasPrefix(prefix) && viewport.insetBy(dx: -0.5, dy: -0.5).contains($0.value) }.count
    }
}

@MainActor private final class ResultSpacePhaseModel: ObservableObject { @Published var phase = FeatureLightfieldPhase.landing }
@MainActor private final class ResultSpaceLayerCapture { var values: [[String: Int]] = [] }
private struct ResultSpacePhaseFixture: View {
    @ObservedObject var model: ResultSpacePhaseModel
    var body: some View {
        FeatureLightfieldPage(module: .uninstall, phase: model.phase, title: "Uninstall", status: model.phase.rawValue,
            safety: "Read only", actionTitle: model.phase.rawValue, action: {}) {
            Text(model.phase.rawValue).layoutProbe("space.phase." + model.phase.rawValue)
        }
    }
}

@MainActor private final class ResultSpaceEnergyModel: ObservableObject {
    @Published var query = ""
    @Published var sort: EnergyImpactSortMode = .estimatedEnergy
}
private struct ResultSpaceEnergyFixture: View {
    @ObservedObject var model: ResultSpaceEnergyModel
    var body: some View {
        LightfieldEnergyPage(snapshot: LightfieldPerformanceFixture.energy, searchText: $model.query, sortMode: $model.sort,
            canRefresh: false, refresh: { XCTFail("No resampling in an identity fixture") }) { EmptyView() }
    }
}
@MainActor private final class ResultSpaceBenchmarkIdentity: BenchmarkV7LeaderboardIdentityProviding {
    func installationID() -> UUID { UUID(uuidString: "A067E670-44B1-4D8F-8F56-76B2C939038A")! }
    func anonymousDisplayName() -> String { "RESULT SPACE FIXTURE" }
    func remember(_ identity: BenchmarkV7LeaderboardSubmittedIdentity) { XCTFail("No identity writes") }
    func forgetSubmittedEntry() { XCTFail("No identity writes") }
    func lastSubmittedIdentity() -> BenchmarkV7LeaderboardSubmittedIdentity? { nil }
}
#endif
