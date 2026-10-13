#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FeatureLightfieldPerformanceTests: XCTestCase {
    private let windows: [CGSize] = [.init(width: 820, height: 560), .init(width: 1000, height: 700),
        .init(width: 1280, height: 763), .init(width: 1680, height: 1050), .init(width: 2400, height: 1350),
        .init(width: 677, height: 390), .init(width: 1280, height: 390)]

    /// B2's titleless options adapter must put the helper and terminal marker
    /// in the same native scroll document, including the reported 655×468.
    func testEnergyOptionsKeepPowerMetricsAndTerminalMarkerReachableAcrossSizes() async throws {
        let monitor = HelperPowerMetricsMonitor(availability: { .needsHelper }, request: {
            XCTFail("An inert energy options fixture must never request power metrics")
            return .failure(.throttled)
        }, automaticSampling: false)
        let defaults = TestPreferenceDomain.make(for: self)
        for dark in [true, false] {
            let root = FeatureLightfieldPage(module: .energy, phase: .landing,
                title: "Energy", status: "Measurement not started", safety: "Read-only measurement",
                actionTitle: "Start Measurement", action: {}) {
                FeatureLightfieldOptions {
                    VStack(alignment: .leading, spacing: 16) {
                        EnergyImpactScanPipelineView(phase: nil, showsStageDetails: true)
                        HelperPowerMetricsView(monitor: monitor, lightfield: true)
                    }
                }
            }.defaultAppStorage(defaults)
                .environment(\.featurePresentationIsFixture, true)
                .environment(\.featureDisablesLayoutAnimations, true)
                .environment(\.moduleTheme, ReviewFilter.energy.moduleTheme)
            let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 655, height: 468), dark: dark)
            defer { host.close() }
            for size in [.init(width: 655, height: 468)] + windows.map({ CGSize(width: $0.width - 210, height: $0.height - 28) }) {
                host.resize(to: size)
                let required: Set<String> = ["lightfield.options.scrollViewport", "lightfield.optionsEnd",
                    "lightfield.primary", "energy.stage.0", "energy.stage.5", "energy.powermetrics.3", "fixture.viewport"]
                let frames = try await host.frames(required: required, size: size)
                let viewport = try XCTUnwrap(frames["lightfield.options.scrollViewport"])
                let primary = try XCTUnwrap(frames["lightfield.primary"])
                XCTAssertEqual(primary.height, 52, accuracy: 0.5)
                XCTAssertLessThanOrEqual(viewport.maxY, primary.minY - 24 + 0.5)
                let bottom = try await host.bottomFrames(required: required, size: size, viewport: viewport)
                let end = try XCTUnwrap(bottom["lightfield.optionsEnd"])
                XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(end), "\(size), dark=\(dark)")
                XCTAssertLessThanOrEqual(try XCTUnwrap(bottom["energy.powermetrics.3"]).maxY, viewport.maxY + 0.5)
                XCTAssertEqual(try XCTUnwrap(bottom["lightfield.primary"]), primary)
                XCTAssertFalse(monitor.hasDemand)
            }
        }
    }

    /// Native AX coverage for the shared controls without a Store operation
    /// fixture. The production row delegates selection to this B2 check.
    func testMemoryCheckAndSelectedPrimaryPublishLocalizedNativePressAndMatchingFrames() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            for dark in [true, false] {
                let model = LightfieldMemoryAXModel()
                let host = CalibrationAppKitLayoutHost(root: LightfieldMemoryAXControls(model: model)
                    .environment(\.featureDisablesLayoutAnimations, true), size: .init(width: 1070, height: 735), dark: dark)
                defer { host.close() }
                let size = CGSize(width: 1070, height: 735)
                let frames = try await host.frames(required: ["fix2.memory.check", "lightfield.primary", "lightfield.primary.hitTarget"], size: size)
                let check = try XCTUnwrap(frames["fix2.memory.check"])
                XCTAssertEqual(check.width, 20, accuracy: 0.5)
                XCTAssertEqual(check.height, 20, accuracy: 0.5)
                let label = L10n.text("选择 Google Chrome", "Select Google Chrome")
                let quit = L10n.text("退出所选应用 · 1 个", "Quit Selected Apps · 1")
                try await host.waitForAccessibility(labels: [label], expectedValues: [label: L10n.text("未选", "Not selected")],
                    pressLabels: [label], hitTestFrames: [check])
                let element = try XCTUnwrap(host.element(label: label, requiresPress: true))
                XCTAssertEqual(element.value(forKey: "accessibilityLabel") as? String, label)
                let nativeCheck = try host.accessibilityFrame(label: label)
                XCTAssertEqual(nativeCheck.minX, check.minX, accuracy: 0.5)
                XCTAssertEqual(nativeCheck.minY, check.minY, accuracy: 0.5)
                XCTAssertEqual(nativeCheck.width, check.width, accuracy: 0.5)
                XCTAssertEqual(nativeCheck.height, check.height, accuracy: 0.5)
                XCTAssertTrue(try host.press(label: label))
                try await host.waitForAccessibility(labels: [label, quit], expectedValues: [label: L10n.text("已选", "Selected")],
                    pressLabels: [label, quit], hitTestFrames: [check, try XCTUnwrap(frames["lightfield.primary"])])
                let primary = try XCTUnwrap(host.element(label: quit, requiresPress: true))
                XCTAssertEqual(primary.value(forKey: "accessibilityLabel") as? String, quit)
                let nativePrimary = try host.accessibilityFrame(label: quit)
                let visiblePrimary = try XCTUnwrap(frames["lightfield.primary"])
                let hitTarget = try XCTUnwrap(frames["lightfield.primary.hitTarget"])
                XCTAssertEqual(visiblePrimary.height, 32, accuracy: 0.5) // D77 visual action
                XCTAssertEqual(nativePrimary.minX, hitTarget.minX, accuracy: 0.5)
                XCTAssertEqual(nativePrimary.minY, hitTarget.minY, accuracy: 0.5)
                XCTAssertEqual(nativePrimary.width, hitTarget.width, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(nativePrimary.height, 44) // fix round 1 native target
                XCTAssertEqual(model.primaryPresses, 0, "Selection never invokes the primary action")
                XCTAssertTrue(try host.press(label: quit))
                XCTAssertEqual(model.primaryPresses, 1)
                model.enabled = false
                try await host.waitForAccessibility(labels: [label, quit], expectedEnabled: [label: false, quit: false],
                    hitTestFrames: [check, try XCTUnwrap(frames["lightfield.primary"])])
                XCTAssertTrue(model.selected)
                XCTAssertEqual(model.primaryPresses, 1)
            }
        }
    }

    /// B0-NOTES: 81% escaped the small occupancy ring at 820×560; the
    /// 1280×763 pressure caption touched its track. Measure real font widths
    /// independently of the layout frames, including very long copy.
    func testB0Occupancy81AndPressureWordsFitTheRingBaseline() async throws {
        for (window, diameter) in [(windows[0], CGFloat(64)), (windows[2], CGFloat(76)), (windows[2], CGFloat(120))] {
            for (value, unit, label) in [("81", "%", "占用"), ("升高", "", "压力"),
                ("12345678901234567890.123456789", "百分比单位", "非常长的压力标签")] {
                let geometry = LightfieldRingGeometry(diameter: diameter)
                let fonts = LightfieldRingTypography(geometry: geometry, value: value, unit: unit, label: label, status: false)
                let number = (value as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: fonts.valueSize, weight: .bold)]).width
                let suffix = unit.isEmpty ? 0 : (unit as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fonts.unitSize, weight: .medium)]).width + 2
                let caption = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fonts.labelSize, weight: .regular)]).width
                XCTAssertLessThanOrEqual(number + suffix, geometry.textBounds.width + 0.5)
                XCTAssertLessThanOrEqual(caption, geometry.textBounds.width + 0.5)
                for dark in [true, false] {
                    let size = CGSize(width: window.width - 210, height: window.height - 28)
                    let host = CalibrationAppKitLayoutHost(root: LightfieldRing(diameter: diameter, progress: 0.81,
                        color: FeatureLightfieldPalette.accent(.memory), value: value, unit: unit, label: label)
                        .environment(\.featureDisablesLayoutAnimations, true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), size: size, dark: dark)
                    defer { host.close() }
                    var required: Set<String> = ["lightfield.ring", "lightfield.ring.text", "lightfield.ring.value",
                        "lightfield.ring.label", "fixture.viewport"]
                    if !unit.isEmpty { required.insert("lightfield.ring.unit") }
                    let frames = try await host.frames(required: required, size: size)
                    let center = try XCTUnwrap(frames["lightfield.ring.text"])
                    XCTAssertTrue(center.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(frames["lightfield.ring.value"])))
                    XCTAssertTrue(center.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(frames["lightfield.ring.label"])))
                    if !unit.isEmpty { XCTAssertTrue(center.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(frames["lightfield.ring.unit"]))) }
                }
            }
        }
    }

    func testProductionPerformancePagesKeepTheSkeletonInThreeStatesSevenSizesAndTwoSchemes() async throws {
        let skeleton = ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status"]
        var references: [String: [String: CGRect]] = [:]
        for dark in [true, false] {
            for module in FeatureLightfield.performancePages {
                for phase in FeatureLightfieldPhase.allCases {
                    let host = CalibrationAppKitLayoutHost(root: try fixture(module: module, phase: phase),
                        size: .init(width: 1070, height: 735), dark: dark)
                    defer { host.close() }
                    for window in windows {
                        let size = CGSize(width: window.width - 210, height: window.height - 28)
                        host.resize(to: size)
                        let frames = try await host.frames(required: Set(skeleton + ["fixture.viewport"]), size: size)
                        let viewport = try XCTUnwrap(frames["fixture.viewport"])
                        let primary = try XCTUnwrap(frames["lightfield.primary"])
                        let content = try XCTUnwrap(frames["lightfield.content"])
                        let status = try XCTUnwrap(frames["lightfield.status"])
                        XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(primary))
                        XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(status))
                        if phase == .result {
                            try assertCompactResultSkeleton(frames, window: window)
                        } else {
                            XCTAssertEqual(primary.height, 52, accuracy: 0.5)
                            XCTAssertEqual(primary.minY - content.maxY, 24, accuracy: 0.5)
                            XCTAssertEqual(status.minY - primary.maxY, 24, accuracy: 0.5)
                        }
                        let key = "\(dark)-\(window)-\(phase == .result)"
                        if let previous = references[key] {
                            for id in skeleton {
                                let actual = try XCTUnwrap(frames[id]), expected = try XCTUnwrap(previous[id])
                                XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5)
                                XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5)
                                XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
                                if id != "lightfield.content" { XCTAssertEqual(actual.width, expected.width, accuracy: 0.5) }
                            }
                        } else { references[key] = frames }
                        if window == windows[2] && phase != .result {
                            XCTAssertEqual(primary.minX, 96, accuracy: 0.5)
                            XCTAssertEqual(primary.minY, 595, accuracy: 0.5)
                            XCTAssertEqual(primary.width, 520, accuracy: 0.5)
                            XCTAssertEqual(content.minX, 96, accuracy: 0.5)
                            XCTAssertEqual(content.minY, 176, accuracy: 0.5)
                            XCTAssertEqual(content.width, phase == .result ? 878 : 520, accuracy: 0.5)
                        }
                    }
                }
            }
        }
    }

    func testMemorySelectionAndExpansionPressAreIndependentAndNeverRequestQuit() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let store = try makeStore(defaults: defaults)
        let snapshot = LightfieldPerformanceFixture.memory
        store.memorySnapshot = snapshot
        let app = try XCTUnwrap(snapshot.appsByResidentUsage.first)
        let root = LightfieldMemoryPage(store: store, snapshot: snapshot, displaySnapshot: snapshot, trendPoints: [],
            startsWithProcesses: true, showsProcesses: .constant(true))
            .defaultAppStorage(defaults).environment(\.featurePresentationIsFixture, true)
            .environment(\.featureDisablesLayoutAnimations, true)
        let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1070, height: 735), dark: true)
        defer { host.close() }
        let frames = try await host.frames(required: ["lightfield.results.scrollViewport", "lightfield.memory.selection." + app.id], size: .init(width: 1070, height: 735))
        let select = L10n.text("选择 \(app.name)", "Select \(app.name)")
        try await host.waitForAccessibility(labels: [select, app.name], expectedValues: [select: L10n.text("未选", "Not selected"),
            app.name: L10n.text("已折叠", "Collapsed")], pressLabels: [select, app.name],
            hitTestFrames: [try XCTUnwrap(frames["lightfield.memory.selection." + app.id])],
            hitTestViewport: try XCTUnwrap(frames["lightfield.results.scrollViewport"]))
        XCTAssertTrue(try host.press(label: select))
        try await host.waitForAccessibility(labels: [select], expectedValues: [select: L10n.text("已选", "Selected")])
        XCTAssertEqual(store.selectedMemoryAppCount, 1)
        XCTAssertEqual(store.selectedMemoryAppEstimatedBytes, app.bytes)
        XCTAssertNil(store.pendingMemoryQuitSummary)
        XCTAssertNil(store.pendingMemoryProcess)
        XCTAssertTrue(try host.press(label: select))
        try await host.waitForAccessibility(labels: [select], expectedValues: [select: L10n.text("未选", "Not selected")])
        XCTAssertEqual(store.selectedMemoryAppCount, 0)
        XCTAssertTrue(try host.press(label: select))
        try await host.waitForAccessibility(labels: [select], expectedValues: [select: L10n.text("已选", "Selected")])
        XCTAssertTrue(try host.press(label: app.name))
        try await host.waitForAccessibility(labels: [app.name], expectedValues: [app.name: L10n.text("已展开", "Expanded")])
        XCTAssertEqual(store.selectedMemoryAppCount, 1, "Expanding/collapsing does not select or quit")
    }

    func testStartupNativeRowsAndSwitchesKeepProtectedItemsReadOnly() async throws {
        var requested: [String] = [], inspected: [String] = []
        for item in MainWindowSnapshotPipeline.startupItemsFixture {
            let root = StartupItemRow(item: item, isPending: false, isPerformingOperation: false,
                onEnable: { requested.append($0.id) }, onDisable: { requested.append($0.id) }, onStop: nil,
                onReveal: nil, onOpenParentApplication: nil, onCopyText: nil, onOpenSystemSettings: nil,
                onInspect: { inspected.append(item.id) })
                .environment(\.featurePresentationIsFixture, true)
            let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 878, height: 80), dark: true)
            defer { host.close() }
            try await host.waitForAccessibility(labels: [item.displayName], expectedValues: [item.displayName: item.displayStatus])
            try nativePress(try XCTUnwrap(host.element(label: item.displayName)))
            XCTAssertEqual(inspected.last, item.id)
            let switchLabel = L10n.text("允许以后启动 · \(item.displayName)", "Allow future launches · \(item.displayName)")
            if let candidate = startupActionCandidate(in: item, onEnable: { _ in }, onDisable: { _ in }) {
                try await host.waitForAccessibility(labels: [switchLabel], expectedValues: [switchLabel: item.displayStatus], pressLabels: [switchLabel])
                let before = requested.count
                try nativePress(try XCTUnwrap(host.element(label: switchLabel)))
                XCTAssertEqual(requested.count, before + 1)
                XCTAssertEqual(requested.last, candidate.id)
            } else {
                XCTAssertNil(host.element(label: switchLabel), "Unknown, managed and protected evidence never creates a switch")
            }
        }
    }

    /// D77: the production route must promote a completed sample to results,
    /// without requiring the old "show processes" button first.
    func testCompletedMemorySampleShowsTenRowsAndGrowsWithWindow() async throws {
        let defaults = TestPreferenceDomain.make(for: self)
        let store = try makeStore(defaults: defaults)
        let base = LightfieldPerformanceFixture.memory
        let processes: [MemoryProcess] = (0..<40).map { index in
            let bundle = "/Applications/Space Memory \(index).app"
            return MemoryProcess(id: Int32(70_000 + index), name: "Memory \(index)",
                path: bundle + "/Contents/MacOS/Fixture", iconPath: bundle, bundlePath: bundle,
                residentBytes: 100_000_000, percent: 1, canQuit: true,
                bundleIdentifier: "invalid.space-memory.\(index)", capturedAt: base.generatedAt, dataSource: .procPIDRUsage)
        }
        let snapshot = MemorySnapshot(generatedAt: base.generatedAt, physicalBytes: base.physicalBytes,
            freeBytes: base.freeBytes, inactiveBytes: base.inactiveBytes, speculativeBytes: base.speculativeBytes,
            fileBackedBytes: base.fileBackedBytes, purgeableBytes: base.purgeableBytes, wiredBytes: base.wiredBytes,
            compressedBytes: base.compressedBytes, swapUsedBytes: base.swapUsedBytes,
            pressureFreePercentage: base.pressureFreePercentage, pressureSummary: base.pressureSummary,
            topProcesses: processes, measurements: base.measurements)
        store.memorySnapshot = snapshot
        let root = LightfieldMemoryPage(store: store, snapshot: snapshot, displaySnapshot: snapshot,
            trendPoints: [], showsResultsWhenSampled: true, showsProcesses: .constant(false))
            .defaultAppStorage(defaults).environment(\.featurePresentationIsFixture, true)
            .environment(\.featureDisablesLayoutAnimations, true)
        let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1070, height: 735), dark: true)
        defer { host.close() }
        var previous = 0
        for size in [CGSize(width: 1070, height: 735), CGSize(width: 1470, height: 1022)] {
            host.resize(to: size)
            let frames = try await host.frames(required: ["lightfield.results.scrollViewport", "fixture.viewport"], size: size)
            let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
            let visible = frames.filter { $0.key.hasPrefix("memory.row.")
                && viewport.insetBy(dx: -0.5, dy: -0.5).contains($0.value) }.count
            XCTAssertGreaterThanOrEqual(visible, 10)
            XCTAssertGreaterThan(visible, previous)
            previous = visible
            XCTAssertFalse(frames.keys.contains { $0.hasPrefix("memory.child.text.") })
            XCTAssertNil(store.pendingMemoryQuitSummary)
        }
    }

    func testEnergyNativeExpansionRevealsReadableChildrenWithoutVisiblePIDs() async throws {
        let app = try XCTUnwrap(LightfieldPerformanceFixture.energy.apps.first)
        let host = CalibrationAppKitLayoutHost(root: LightfieldEnergyAppRow(app: app, maximum: 5,
            sortMode: .estimatedEnergy, metricsWidth: 336, initiallyExpanded: true)
            .environment(\.featurePresentationIsFixture, true).environment(\.featureDisablesLayoutAnimations, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
            size: .init(width: 878, height: 300), dark: false)
        defer { host.close() }
        let more = L10n.text("再显示 \(app.processIDs.count - 1) 个", "Show \(app.processIDs.count - 1) More")
        try await host.waitForAccessibility(labels: [app.name, more], expectedValues: [app.name: L10n.text("已展开", "Expanded")],
            pressLabels: [app.name, more])
        XCTAssertTrue(try host.press(label: more))
        XCTAssertTrue(try host.press(label: app.name))
        try await host.waitForAccessibility(labels: [app.name], expectedValues: [app.name: L10n.text("已折叠", "Collapsed")])
        XCTAssertTrue(try host.press(label: app.name))
        try await host.waitForAccessibility(labels: [app.name], expectedValues: [app.name: L10n.text("已展开", "Expanded")])
        XCTAssertNil(host.element(label: more), "Expansion preserves the user's show-all choice")
        for id in app.processIDs { XCTAssertNil(host.element(label: String(id)), "PID is only in help") }
        let names = LightfieldPerformanceFixture.energyProcessNames(app)
        let renderer = try XCTUnwrap(names.values.first { $0.contains(L10n.text("网页渲染", "Web Renderer")) })
        try await host.waitForAccessibility(labels: [renderer], expectedValues: [renderer: "—"])
        let frames = try await host.frames(required: Set(app.processIDs.map { "energy.child.icon.\($0)" }),
            size: .init(width: 878, height: 300))
        for id in app.processIDs {
            let icon = try XCTUnwrap(frames["energy.child.icon.\(id)"])
            let text = try XCTUnwrap(frames["energy.child.text.\(id)"])
            XCTAssertEqual(icon.width, CGFloat(LightfieldAppIcon.Size.medium.rawValue), accuracy: 0.5)
            XCTAssertEqual(icon.height, CGFloat(LightfieldAppIcon.Size.medium.rawValue), accuracy: 0.5)
            XCTAssertEqual(text.minX - icon.maxX, 16, accuracy: 0.5)
        }
    }

    func testEnergySummaryUsesCurrentEvidenceIndependentlyOfCumulativeCounters() throws {
        var estimated = try XCTUnwrap(LightfieldPerformanceFixture.energy.apps.first)
        XCTAssertEqual(estimated.cumulativeEvidence.source, .systemData)
        estimated.currentMeasuredProcessCount = 0
        XCTAssertEqual(LightfieldPerformancePresentation.currentEnergySource([estimated]), .estimated)
        XCTAssertEqual(LightfieldPerformancePresentation.currentEnergySource(LightfieldPerformanceFixture.energy.apps + [estimated]), .mixed)
        estimated.currentSampleSeconds = nil
        XCTAssertEqual(LightfieldPerformancePresentation.currentEnergySource([estimated]), .unknown)
        XCTAssertEqual(LightfieldPerformancePresentation.currentEnergySource([]), .unknown)
    }

    func testResultViewportAndLastItemStayReachableAtNormalAndShortHeights() async throws {
        for module in FeatureLightfield.performancePages {
            for window in [windows[2], windows[5]] {
                let size = CGSize(width: window.width - 210, height: window.height - 28)
                let host = CalibrationAppKitLayoutHost(root: try fixture(module: module, phase: .result), size: size, dark: false)
                defer { host.close() }
                let frames = try await host.frames(required: ["lightfield.content", "lightfield.primary",
                    "lightfield.results.scrollViewport", "lightfield.results.fade", "fixture.viewport"], size: size)
                let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
                XCTAssertGreaterThan(viewport.height, 0)
                XCTAssertEqual(viewport.maxY, try XCTUnwrap(frames["lightfield.content"]).maxY, accuracy: 0.5)
                XCTAssertLessThanOrEqual(viewport.maxY, try XCTUnwrap(frames["lightfield.primary"]).minY - 16 + 0.5)
                // D77 keeps the full clip viewport instead of shortening it
                // to a row boundary. The footer never shares that clip.
                XCTAssertTrue(try XCTUnwrap(frames["lightfield.content"]).insetBy(dx: -0.5, dy: -0.5).contains(viewport))
                XCTAssertEqual(try XCTUnwrap(frames["lightfield.results.fade"]).maxY, viewport.maxY, accuracy: 0.5)
                let id: String
                if module == .startup {
                    let last = try XCTUnwrap(StartupItemsPresentation.make(items: MainWindowSnapshotPipeline.startupItemsFixture,
                        query: "", category: .all, status: .all, source: .all, includeAppleSystem: false,
                        sort: .recommended, includeTechnicalDetails: false).visibleItems.last)
                    id = "startup.row." + last.id
                } else if module == .memory {
                    id = "memory.row." + (try XCTUnwrap(LightfieldPerformanceFixture.memory.appsByResidentUsage.last)).id
                } else {
                    id = "energy.row." + (try XCTUnwrap(EnergyImpactSortMode.estimatedEnergy.sorted(LightfieldPerformanceFixture.energy.apps).last)).id
                }
                let after = try await host.bottomFrames(required: [id, "lightfield.results.scrollViewport"], size: size, viewport: viewport)
                let last = try XCTUnwrap(after[id])
                XCTAssertGreaterThan(last.maxY, viewport.minY - 0.5)
                XCTAssertLessThanOrEqual(last.maxY, viewport.maxY + 0.5)
            }
        }
    }

    func testLongNamesAndNumericGroupsStayInsideTheRowAtSevenWidths() async throws {
        let original = try XCTUnwrap(LightfieldPerformanceFixture.memory.appsByResidentUsage.first)
        let app = MemoryAppUsage(id: original.id, name: String(repeating: "非常长的应用名称", count: 30), iconPath: "", bundlePath: original.bundlePath,
            bytes: original.bytes, canQuit: true, isActive: false, percent: original.percent,
            processCount: original.processCount, processIDs: original.processIDs, selectableProcessIDs: original.selectableProcessIDs)
        let store = try makeStore(defaults: TestPreferenceDomain.make(for: self))
        store.memorySnapshot = LightfieldPerformanceFixture.memory
        let energy = try XCTUnwrap(LightfieldPerformanceFixture.energy.apps.first)
        let longEnergy = EnergyImpactApp(id: energy.id, name: app.name, path: energy.path, iconPath: energy.iconPath,
            bundlePath: energy.bundlePath, bundleIdentifier: energy.bundleIdentifier, measuredEnergyWh: energy.measuredEnergyWh,
            estimatedSupplementEnergyWh: energy.estimatedSupplementEnergyWh, estimatedEnergyWh: energy.estimatedEnergyWh,
            currentPowerWatts: energy.currentPowerWatts, averagePowerWatts: energy.averagePowerWatts, cpuPercent: energy.cpuPercent,
            diskReadBytesPerSecond: energy.diskReadBytesPerSecond, diskWriteBytesPerSecond: energy.diskWriteBytesPerSecond,
            residentBytes: energy.residentBytes, cumulativeCPUSeconds: energy.cumulativeCPUSeconds,
            longestRunningSeconds: energy.longestRunningSeconds, processCount: energy.processCount,
            measuredProcessCount: energy.measuredProcessCount, processIDs: energy.processIDs, isApplication: energy.isApplication,
            currentMeasuredProcessCount: energy.currentMeasuredProcessCount, sampledAt: energy.sampledAt, currentSampleSeconds: energy.currentSampleSeconds)
        var startup = try XCTUnwrap(MainWindowSnapshotPipeline.startupItemsFixture.first)
        startup.name = app.name; startup.attribution = nil; startup.components = []
        for window in windows {
            let width = FeatureLightfieldGeometry(size: .init(width: window.width - 210, height: window.height - 28), phase: .result).content.width
            let size = CGSize(width: width, height: 200)
            let host = CalibrationAppKitLayoutHost(root: LightfieldMemoryAppRow(app: app, processes: [], store: store)
                .environment(\.featurePresentationIsFixture, true).environment(\.featureDisablesLayoutAnimations, true)
                .layoutProbe("row")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), size: size, dark: true)
            defer { host.close() }
            let prefix = "memory.values." + app.id
            let frames = try await host.frames(required: ["row", prefix, prefix + ".column.memory", prefix + ".value.memory"], size: size)
            let row = try XCTUnwrap(frames["row"])
            XCTAssertTrue(row.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(frames[prefix])))
            XCTAssertTrue(try XCTUnwrap(frames[prefix + ".column.memory"]).insetBy(dx: -0.5, dy: -0.5)
                .contains(try XCTUnwrap(frames[prefix + ".value.memory"])))
            let energyHost = CalibrationAppKitLayoutHost(root: LightfieldEnergyAppRow(app: longEnergy, maximum: 5,
                sortMode: .estimatedEnergy, metricsWidth: min(336, max(144, width * 0.4)))
                .environment(\.featurePresentationIsFixture, true).environment(\.featureDisablesLayoutAnimations, true).layoutProbe("row")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), size: size, dark: false)
            defer { energyHost.close() }
            let energyPrefix = "energy.values." + energy.id
            let energyFrames = try await energyHost.frames(required: ["row", energyPrefix, energyPrefix + ".value.current"], size: size)
            XCTAssertTrue(try XCTUnwrap(energyFrames["row"]).insetBy(dx: -0.5, dy: -0.5)
                .contains(try XCTUnwrap(energyFrames[energyPrefix])))
            let startupHost = CalibrationAppKitLayoutHost(root: StartupItemRow(item: startup, isPending: false,
                isPerformingOperation: false, onEnable: nil, onDisable: nil, onStop: nil, onReveal: nil,
                onOpenParentApplication: nil, onCopyText: nil, onOpenSystemSettings: nil, onInspect: {})
                .environment(\.featurePresentationIsFixture, true).environment(\.featureDisablesLayoutAnimations, true).layoutProbe("row")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), size: size, dark: false)
            defer { startupHost.close() }
            let startupFrames = try await startupHost.frames(required: ["row", "startup.name." + startup.id], size: size)
            XCTAssertTrue(try XCTUnwrap(startupFrames["row"]).insetBy(dx: -0.5, dy: -0.5)
                .contains(try XCTUnwrap(startupFrames["startup.name." + startup.id])))
        }
    }

    /// The result adapter must virtualize real stable rows, not merely contain
    /// a LazyVStack token. The 400-row/60-row budget is the existing D67
    /// production-uninstall regression, shared here with energy.
    func testEnergyProductionResultKeepsALazyListAndLastAppReachableAtSevenSizes() async throws {
        let apps: [EnergyImpactApp] = (0..<400).map(Self.lazyEnergyApp)
        let processCount = apps.reduce(0) { $0 + $1.processIDs.count }
        let snapshot = EnergyImpactSnapshot(generatedAt: LightfieldPerformanceFixture.date, scanSeconds: 3,
            sampleSeconds: 1, uptimeSeconds: 60, apps: apps, processCount: processCount, measuredProcessCount: processCount,
            unmeasuredProcessCount: 0, measuredTotalEnergyWh: apps.reduce(0) { $0 + $1.measuredEnergyWh },
            estimatedSupplementEnergyWh: 0, calibrationWattsPerCore: 2, usesLocalCalibration: true)
        for dark in [true, false] {
            for window in windows {
                let size = CGSize(width: window.width - 210, height: window.height - 28)
                let naming = EnergyNamingReadProbe(blocksFirstRead: true) { _ in
                    "/Fixture/Energy0.app/Contents/MacOS/Browser Helper (Renderer)"
                }
                defer { naming.release() }
                let root = AdaptivePageViewport(resetID: .energy) {
                    LightfieldEnergyPage(snapshot: snapshot, searchText: .constant(""), sortMode: .constant(.estimatedEnergy),
                        canRefresh: true, refresh: {}) { EmptyView() }
                }.environment(\.featurePresentationIsFixture, true).environment(\.featureDisablesLayoutAnimations, true)
                    .environment(\.lightfieldEnergyProcessResolver, naming.resolver)
                let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: dark)
                defer { host.close() }
                // D77 keeps the first app collapsed; child reads start only
                // after an explicit disclosure. The async/non-main-thread
                // responsiveness contract is still measured during that read.
                let firstFrames = try await host.frames(required: ["energy.row." + apps[0].id,
                    "lightfield.results.scrollViewport"], size: size)
                let firstRow = try XCTUnwrap(firstFrames["energy.row." + apps[0].id])
                let firstViewport = try XCTUnwrap(firstFrames["lightfield.results.scrollViewport"])
                try host.scrollOptionsToReveal(firstRow, matching: firstViewport)
                try await host.waitForAccessibility(labels: [apps[0].name], pressLabels: [apps[0].name],
                    hitTestFrames: [firstRow], hitTestViewport: firstViewport)
                XCTAssertTrue(try host.press(label: apps[0].name))
                try await naming.waitForBlockedRead()
                XCTAssertTrue(naming.snapshot.waiting, "The native page must remain responsive during path reads")
                XCTAssertEqual(naming.snapshot.mainThreadOperations, 0)
                let frames = try await host.frames(required: ["lightfield.listDocument", "lightfield.results.scrollViewport",
                    "lightfield.primary", "fixture.viewport"], size: size)
                XCTAssertTrue(naming.snapshot.waiting, "Geometry must converge while the production read is held")
                naming.release()
                try await naming.waitForNamedPIDs(256)
                // Initial GeometryReader tier changes may cancel an appearance
                // and create a new pass. Each pass must reuse its own buffer.
                XCTAssertEqual(Set(naming.snapshot.buffersByReader.keys), Set(naming.snapshot.readsByReader.keys))
                XCTAssertTrue(naming.snapshot.buffersByReader.values.allSatisfy { $0.count == 1 })
                XCTAssertEqual(naming.snapshot.mainThreadOperations, 0)
                XCTAssertFalse(naming.snapshot.gateExpired)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames["lightfield.listDocument"]).height, CGFloat(400 * 48))
                XCTAssertLessThan(frames.keys.filter { $0.hasPrefix("energy.row.") }.count, 60)
                XCTAssertNil(frames["energy.row.lazy-energy-399"])
                let viewport = try XCTUnwrap(frames["lightfield.results.scrollViewport"])
                let primary = try XCTUnwrap(frames["lightfield.primary"])
                XCTAssertLessThanOrEqual(viewport.maxY, primary.minY - 16 + 0.5)
                let after = try await host.bottomFrames(required: ["energy.row.lazy-energy-399", "lightfield.primary",
                    "lightfield.results.scrollViewport"], size: size, viewport: viewport)
                let last = try XCTUnwrap(after["energy.row.lazy-energy-399"])
                XCTAssertGreaterThan(last.maxY, viewport.minY - 0.5)
                XCTAssertLessThanOrEqual(last.maxY, viewport.maxY + 0.5)
                XCTAssertEqual(try XCTUnwrap(after["lightfield.primary"]), primary)
            }
        }
    }

    private static func lazyEnergyApp(_ index: Int) -> EnergyImpactApp {
        let energy = Double(400 - index)
        let pid = Int32(90_000 + index)
        let pids = index == 0 ? (100_000..<100_256).map(Int32.init) : [pid]
        let bundle = "/Fixture/Energy\(index).app"
        return EnergyImpactApp(id: "lazy-energy-\(index)", name: "Energy Fixture \(index)", path: bundle + "/Contents/MacOS/Browser",
                iconPath: bundle, bundlePath: bundle, bundleIdentifier: nil, measuredEnergyWh: energy,
                estimatedSupplementEnergyWh: 0, estimatedEnergyWh: energy,
                currentPowerWatts: 1, averagePowerWatts: 1, cpuPercent: 1, diskReadBytesPerSecond: 0,
                diskWriteBytesPerSecond: 0, residentBytes: 1024, cumulativeCPUSeconds: 1, longestRunningSeconds: 60,
                processCount: pids.count, measuredProcessCount: pids.count, processIDs: pids, isApplication: true,
                currentMeasuredProcessCount: pids.count, sampledAt: LightfieldPerformanceFixture.date, currentSampleSeconds: 1)
    }

    private func fixture(module: ReviewFilter, phase: FeatureLightfieldPhase) throws -> some View {
        let defaults = TestPreferenceDomain.make(for: self)
        let store = try makeStore(defaults: defaults)
        store.memorySnapshot = LightfieldPerformanceFixture.memory
        let view: AnyView
        if phase == .running {
            view = AnyView(FeatureDemoRunningFixture(module: module, onCancel: {}))
        } else if module == .startup {
            if phase == .landing {
                view = AnyView(LightfieldStartupLandingView(items: MainWindowSnapshotPipeline.startupItemsFixture, canRefresh: true, onStart: {}))
            } else {
                view = AnyView(StartupItemsDashboardView(items: MainWindowSnapshotPipeline.startupItemsFixture,
                    isLoading: false, progress: nil, coverageAction: AnyView(EmptyView()), onRefresh: {}, onCancel: {}))
            }
        } else if module == .memory {
            view = AnyView(LightfieldMemoryPage(store: store, snapshot: LightfieldPerformanceFixture.memory,
                displaySnapshot: LightfieldPerformanceFixture.memory, trendPoints: LightfieldPerformanceFixture.trend,
                startsWithProcesses: phase == .result, showsProcesses: .constant(phase == .result)))
        } else if phase == .landing {
            view = AnyView(EnergyImpactScanLandingView(store: store))
        } else {
            view = AnyView(LightfieldEnergyPage(snapshot: LightfieldPerformanceFixture.energy, searchText: .constant(""),
                sortMode: .constant(.estimatedEnergy), canRefresh: true, refresh: {}) { EmptyView() })
        }
        return AdaptivePageViewport(resetID: module) { view }
            .defaultAppStorage(defaults).environment(\.featurePresentationIsFixture, true)
            .environment(\.featureLightfieldModule, module).environment(\.featureDisablesLayoutAnimations, true)
            .transaction { $0.disablesAnimations = true }
    }
    private func makeStore(defaults: UserDefaults) throws -> ScanStore {
        try ScanStore.makeForTests(for: self, loadScanReadinessSummary: { ScanReadinessSummary(items: []) },
            scanHistoryDefaults: defaults, preferences: defaults,
            menuBarMemoryStatusProvider: { XCTFail("No live memory status in B3 fixture"); return LightfieldPerformanceFixture.memory },
            menuBarMemoryProcessProvider: { XCTFail("No live memory process scan in B3 fixture"); return LightfieldPerformanceFixture.memory },
            cleanupScanOperation: { _, _ in XCTFail("No cleanup in B3 fixture"); throw CancellationError() },
            cleanupPreferences: defaults, cleanReportLoader: { [] }, interruptedOperationReconciler: { [] })
    }

    /// Switches and container rows expose public AXPress with different roles.
    /// Invoke the actual native action, without fabricating an AX node or value.
    private func nativePress(_ element: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(element.responds(to: selector))
        guard element.responds(to: selector) else { return }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = try XCTUnwrap(element.method(for: selector))
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(element, selector))
    }
}

@MainActor
private final class LightfieldMemoryAXModel: ObservableObject {
    @Published var selected = false
    @Published var enabled = true
    var primaryPresses = 0
}

private struct LightfieldMemoryAXControls: View {
    @ObservedObject var model: LightfieldMemoryAXModel
    private var actionTitle: String {
        model.selected ? L10n.text("退出所选应用 · 1 个", "Quit Selected Apps · 1")
            : L10n.text("刷新内存快照", "Refresh Memory Snapshot")
    }
    var body: some View {
        FeatureLightfieldPage(module: .memory, phase: .result, title: "Memory", status: "Pressure Normal",
            safety: "Save your work", actionTitle: actionTitle, actionAccessibilityLabel: actionTitle,
            actionEnabled: model.enabled, showsArtwork: false, action: { model.primaryPresses += 1 }) {
            FeatureLightfieldCheck(selected: model.selected, module: .memory,
                accessibilityLabel: L10n.text("选择 Google Chrome", "Select Google Chrome"), action: { model.selected.toggle() })
                .disabled(!model.enabled)
                .lightfieldComponentProbe("fix2.memory.check")
        }
    }
}
#endif
