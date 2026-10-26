#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FeatureLightfieldApplicationPageTests: XCTestCase {
    private let windows: [CGSize] = [.init(width: 820, height: 560), .init(width: 1000, height: 700),
        .init(width: 1280, height: 763), .init(width: 1680, height: 1050), .init(width: 2400, height: 1350),
        .init(width: 677, height: 390), .init(width: 1280, height: 390)]

    func testApplicationPagesKeepProductionSkeletonAcrossThreeStatesSevenSizesAndTwoSchemes() async throws {
        let store = try makeStore()
        store.installedApps = FeatureLightfieldApplicationsFixture.uninstallApps
        store.hasScannedInstalledApps = true
        let ids: Set<String> = ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status", "fixture.viewport"]
        var references: [String: [String: CGRect]] = [:]
        for dark in [true, false] {
            for module in [ReviewFilter.uninstall, .updater] {
                // D154: the uninstall result is CleanMyMac's Applications manager
                // (`FeatureLightfieldContractTests.testUninstallManager…`).
                for phase in FeatureLightfieldPhase.allCases where !(module == .uninstall && phase == .result) {
                    let host = CalibrationAppKitLayoutHost(root: page(module: module, phase: phase, store: store),
                        size: .init(width: 1070, height: 735), dark: dark)
                    defer { host.close() }
                    for window in windows {
                        let size = CGSize(width: window.width - 210, height: window.height - 28)
                        host.resize(to: size)
                        let frames = try await host.frames(required: ids, size: size)
                        let content = try XCTUnwrap(frames["lightfield.content"])
                        let primary = try XCTUnwrap(frames["lightfield.primary"])
                        let status = try XCTUnwrap(frames["lightfield.status"])
                        let viewport = try XCTUnwrap(frames["fixture.viewport"])
                        XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(content))
                        XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(primary))
                        XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(status))
                        let compact = module == .uninstall && phase == .result
                        if compact {
                            try assertCompactResultSkeleton(frames, window: window)
                        } else {
                            XCTAssertEqual(primary.height, 52, accuracy: 0.5)
                            XCTAssertEqual(primary.minY - content.maxY, 24, accuracy: 0.5)
                            XCTAssertEqual(status.minY - primary.maxY, 24, accuracy: 0.5)
                        }
                        let key = "\(dark)/\(window)/\(compact)"
                        if let previous = references[key] {
                            for id in ["lightfield.title", "lightfield.primary", "lightfield.status"] {
                                assertEqual(try XCTUnwrap(frames[id]), try XCTUnwrap(previous[id]))
                            }
                            XCTAssertEqual(content.minX, try XCTUnwrap(previous["lightfield.content"]).minX, accuracy: 0.5)
                            XCTAssertEqual(content.minY, try XCTUnwrap(previous["lightfield.content"]).minY, accuracy: 0.5)
                        } else { references[key] = frames }
                        if window == CGSize(width: 1280, height: 763) && !compact {
                            assertEqual(primary, CGRect(x: 96, y: 595, width: 520, height: 52))
                            XCTAssertEqual(try XCTUnwrap(frames["lightfield.title"]).minX, 96, accuracy: 0.5)
                            XCTAssertEqual(try XCTUnwrap(frames["lightfield.title"]).minY, 92, accuracy: 0.5)
                            assertEqual(content, CGRect(x: 96, y: 176, width: phase == .result ? 878 : 520, height: 395))
                        }
                        if phase == .result {
                            let list = try await host.frames(required: ["lightfield.results.scrollViewport", "fixture.viewport"], size: size)
                            XCTAssertLessThanOrEqual(try XCTUnwrap(list["lightfield.results.scrollViewport"]).maxY, content.maxY + 0.5)
                            if module == .updater {
                                let counts = try await host.frames(required: ["lightfield.updater.metrics", "fixture.viewport"], size: size)
                                let metricsHeight = try XCTUnwrap(counts["lightfield.updater.metrics"]).height
                                XCTAssertGreaterThanOrEqual(metricsHeight, 48)
                                if window.width >= 1280 { XCTAssertEqual(metricsHeight, 48, accuracy: 0.5) }
                            } else {
                                let parts = ["leading", "nameColumn", "detailColumn", "trailingColumn"]
                                let headers = try await host.frames(required: Set(parts.flatMap {
                                    ["lightfield.uninstall.header." + $0, "lightfield.uninstall.item.0." + $0]
                                }), size: size)
                                for part in parts {
                                    let header = try XCTUnwrap(headers["lightfield.uninstall.header." + part])
                                    let row = try XCTUnwrap(headers["lightfield.uninstall.item.0." + part])
                                    XCTAssertEqual(header.minX, row.minX, accuracy: 0.5)
                                    XCTAssertEqual(header.maxX, row.maxX, accuracy: 0.5)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testLongApplicationNamesVersionsPathsAndHandlingNeverCrossTheirColumns() async throws {
        let longApp = InstalledAppItem(id: "long-path", name: String(repeating: "很长的应用名称", count: 12),
            bundleIdentifier: "invalid.example.lightfield.long", path: "/Fixture/" + String(repeating: "很长的目录/", count: 30) + "Sample.app",
            version: String(repeating: "1234567890.", count: 10), build: "", category: "", appDescription: "", sizeBytes: 100,
            source: "fixture", modifiedAt: nil, relatedPaths: [], relatedItems: [], status: .installed)
        let update = try XCTUnwrap(AppUpdateLightfieldPresentation(summary: FeatureLightfieldApplicationsFixture.updateSummary(stress: true)).entries.first)
        for dark in [true, false] {
            for window in windows {
                let canvas = CGSize(width: window.width - 210, height: window.height - 28)
                let width = FeatureLightfieldGeometry(size: canvas, phase: .result).content.width
                let size = CGSize(width: width, height: 140)
                let root = VStack(spacing: 0) {
                    FeatureLightfieldUninstallList(apps: [longApp], selectedID: nil, select: { _ in }, review: { _ in })
                    AppUpdateLightfieldRow(entry: update, index: 0, onReview: {})
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .environment(\.featureDisablesLayoutAnimations, true)
                let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: dark)
                defer { host.close() }
                let ids: Set<String> = ["lightfield.uninstall.item.0", "lightfield.uninstall.item.0.nameColumn", "lightfield.uninstall.item.0.detailColumn",
                    "lightfield.uninstall.item.0.icon", "lightfield.uninstall.item.0.name", "lightfield.uninstall.item.0.version", "lightfield.uninstall.item.0.path",
                    "lightfield.updater.item.0", "lightfield.updater.item.0.nameColumn", "lightfield.updater.item.0.detailColumn", "lightfield.updater.item.0.trailingColumn",
                    "lightfield.updater.item.0.icon", "lightfield.updater.item.0.name", "lightfield.updater.item.0.versions", "lightfield.updater.item.0.handling", "fixture.viewport"]
                let frames = try await host.frames(required: ids, size: size)
                for prefix in ["lightfield.uninstall.item.0", "lightfield.updater.item.0"] {
                    let row = try XCTUnwrap(frames[prefix])
                    XCTAssertEqual(row.height, 52, accuracy: 0.5)
                    XCTAssertEqual(try XCTUnwrap(frames[prefix + ".icon"]).size, .init(width: 24, height: 24))
                    for column in ["nameColumn", "detailColumn"] {
                        XCTAssertTrue(row.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(frames[prefix + "." + column])))
                    }
                    contains(frames, parent: prefix + ".nameColumn", child: prefix + ".name")
                }
                contains(frames, parent: "lightfield.uninstall.item.0.nameColumn", child: "lightfield.uninstall.item.0.version")
                contains(frames, parent: "lightfield.uninstall.item.0.detailColumn", child: "lightfield.uninstall.item.0.path")
                contains(frames, parent: "lightfield.updater.item.0.detailColumn", child: "lightfield.updater.item.0.versions")
                contains(frames, parent: "lightfield.updater.item.0.trailingColumn", child: "lightfield.updater.item.0.handling")
                let name = try XCTUnwrap(frames["lightfield.uninstall.item.0.nameColumn"])
                let path = try XCTUnwrap(frames["lightfield.uninstall.item.0.detailColumn"])
                XCTAssertGreaterThanOrEqual(path.minX - name.maxX, 16 - 0.5)
            }
        }
    }

    func testSixInlineMetricsContainLongValuesAndReadTheirCompleteLabels() async throws {
        // B4 P2: probes must surround intrinsic, fixed-size glyphs, not clipped
        // frames. Complete glyph widths are independently checked in P2Tests.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift"), encoding: .utf8)
        let group = try r2SourceDeclaration("struct LightfieldMetricGroup: View", in: source)
        let inline = group.components(separatedBy: "private var stackedMetrics")[0]
        XCTAssertTrue(inline.contains("LightfieldInlineMetricsLayout"))
        XCTAssertEqual(inline.components(separatedBy: ".fixedSize()").count - 1, 2)
        for forbidden in [".clipped()", ".minimumScaleFactor", ".truncationMode", ".lineLimit"] {
            XCTAssertFalse(inline.contains(forbidden), "Inline statistics cannot conceal truncated glyphs")
        }
        let metrics = AppUpdateLightfieldPresentation(summary: FeatureLightfieldApplicationsFixture.updateSummary()).metrics
        for window in windows {
            let canvas = CGSize(width: window.width - 210, height: window.height - 28)
            let width = FeatureLightfieldGeometry(size: canvas, phase: .result).content.width
            let long = metrics.map { LightfieldMetric(id: $0.id, label: $0.label, value: "12345678901234567890", status: $0.status) }
            for values in [metrics, long] {
                let size = CGSize(width: width, height: 420)
                let host = CalibrationAppKitLayoutHost(root: LightfieldMetricGroup(metrics: values, style: .inline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), size: size, dark: true)
                defer { host.close() }
                let ids = Set(["lightfield.metrics", "fixture.viewport"] + values.flatMap { metric in
                    ["column", "value", "label"].map { "lightfield.metrics." + $0 + "." + metric.id }
                })
                let frames = try await host.frames(required: ids, size: size)
                let groupFrame = try XCTUnwrap(frames["lightfield.metrics"])
                XCTAssertGreaterThanOrEqual(groupFrame.height, 48)
                contains(frames, parent: "fixture.viewport", child: "lightfield.metrics")
                for value in values {
                    contains(frames, parent: "lightfield.metrics", child: "lightfield.metrics.column." + value.id)
                    for child in ["value", "label"] {
                        contains(frames, parent: "lightfield.metrics.column." + value.id, child: "lightfield.metrics." + child + "." + value.id)
                    }
                    let column = try XCTUnwrap(frames["lightfield.metrics.column." + value.id])
                    let number = try XCTUnwrap(frames["lightfield.metrics.value." + value.id])
                    let label = try XCTUnwrap(frames["lightfield.metrics.label." + value.id])
                    if label.minY >= number.maxY - 0.5 {
                        XCTAssertEqual(number.minX, column.minX, accuracy: 0.5)
                        XCTAssertLessThanOrEqual(number.width, column.width + 0.5,
                            "Complete intrinsic numerals must fit without scaling")
                    }
                }
                try await host.waitForAccessibility(labels: values.map { $0.label + " · " + $0.value + " " })
            }
        }
    }

    func testUpdateRowOpensReviewAndPrimaryAXPressInvokesAutomaticBatch() async throws {
        let callbacks = LightfieldApplicationCallbacks()
        let summary = FeatureLightfieldApplicationsFixture.updateSummary()
        let first = try XCTUnwrap(AppUpdateLightfieldPresentation(summary: summary).entries.first)
        let root = AppUpdateScanSummaryPage(summary: summary, warnings: [], canManage: true, canRescan: true,
            onUpdateAll: { callbacks.previewCount += 1 }, onManage: { callbacks.reviewCount += 1 }, onRescan: { callbacks.scanCount += 1 })
            .environment(\.featureDisablesLayoutAnimations, true)
            .environment(\.featureOperationHistoryAction, { callbacks.historyCount += 1 })
        let size = CGSize(width: 1070, height: 735)
        let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
        defer { host.close() }
        let frames = try await host.frames(required: ["lightfield.primary", "lightfield.results.scrollViewport", "lightfield.updater.item.0", "fixture.viewport"], size: size)
        let row = first.application.displayName + " · " + first.application.installedVersion.display + " → " + (first.application.availableVersion?.display ?? "—")
        let primary = L10n.text("全部更新 · 4 个", "Update All · 4")
        let history = L10n.text("操作记录", "Operation History")
        try await host.waitForAccessibility(labels: [row, primary, history],
            expectedValues: [row: L10n.text("可直接更新", "Automatic")], pressLabels: [row, primary, history],
            hitTestViewport: try XCTUnwrap(frames["lightfield.results.scrollViewport"]))
        XCTAssertTrue(try host.press(label: row))
        XCTAssertEqual(callbacks.reviewCount, 1)
        XCTAssertTrue(try host.press(label: primary))
        XCTAssertEqual(callbacks.reviewCount, 1)
        XCTAssertEqual(callbacks.previewCount, 1)
        XCTAssertEqual(callbacks.scanCount, 0)
        XCTAssertTrue(try host.press(label: history))
        XCTAssertEqual(callbacks.historyCount, 1)
        XCTAssertEqual(summary.applications, FeatureLightfieldApplicationsFixture.updateApplications)
    }

    func testReferenceFixtureUsesSevenChecksFiveUpdatesAndAllSixCounts() throws {
        let summary = FeatureLightfieldApplicationsFixture.updateSummary()
        let presentation = AppUpdateLightfieldPresentation(summary: summary)
        XCTAssertEqual(summary.scannedCount, 7)
        XCTAssertEqual(presentation.entries.count, 5)
        XCTAssertEqual(presentation.metrics.map(\.value), ["2", "1", "1", "1", "1", "1"])
        XCTAssertEqual(FeatureLightfieldApplicationsFixture.uninstallApps.count, 5)
        XCTAssertEqual(FeatureLightfieldApplicationsFixture.uninstallApps.reduce(Int64(0)) { $0 + $1.sizeBytes }, 40_800_000_000)
        XCTAssertNotNil(FeaturePresentationDemo.configuration(arguments: [MiniWindowDemoData.launchArgument, "--debug-feature-page=updater:result"]))
    }

    func testLandingOptionIconsAre28PointsAndOnlyPrimaryStartsTheCheck() async throws {
        let callbacks = LightfieldApplicationCallbacks()
        let store = try makeStore()
        for module in [ReviewFilter.uninstall, .updater] {
            let root = Group {
                if module == .uninstall { AppUninstallScanLandingView(store: store) }
                else { AppUpdateIdlePage(lastSummary: nil, canScan: true, onScan: { callbacks.scanCount += 1 }, onManage: {}) }
            }.environment(\.featureDisablesLayoutAnimations, true)
            let size = CGSize(width: 1070, height: 735)
            let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: false)
            defer { host.close() }
            let ids = module == .uninstall ? ["system", "user", "related"] : ["packages", "store", "feed", "website"]
            let prefix = "lightfield." + module.rawValue + ".option."
            let frames = try await host.frames(required: Set(["fixture.viewport"] + ids.flatMap { [prefix + $0, prefix + $0 + ".icon"] }), size: size)
            for id in ids {
                XCTAssertEqual(try XCTUnwrap(frames[prefix + id]).height, 56, accuracy: 0.5)
                XCTAssertEqual(try XCTUnwrap(frames[prefix + id + ".icon"]).size, .init(width: 28, height: 28))
            }
            if module == .updater {
                let label = L10n.text("检查更新", "Check for Updates")
                try await host.waitForAccessibility(labels: [label], pressLabels: [label])
                XCTAssertTrue(try host.press(label: label))
                XCTAssertEqual(callbacks.scanCount, 1)
            }
        }
    }

    func testUninstallSummaryCountAndPrimaryNeverOverlapAtResultWidths() async throws {
        for window in windows {
            let canvas = CGSize(width: window.width - 210, height: window.height - 28)
            let size = CGSize(width: FeatureLightfieldGeometry(size: canvas, phase: .result).content.width, height: 90)
            let root = LightfieldSummary(module: .uninstall, label: L10n.text("可审阅总量", "Total to Review"), value: "40.8", unit: "GB",
                secondary: [.init(id: "apps", label: L10n.text("应用与相关文件", "Apps and Related Files"), value: "5", unit: L10n.text("个应用", "apps"))],
                showsArtwork: false).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
            defer { host.close() }
            let frames = try await host.frames(required: ["lightfield.summary", "lightfield.summary.primary", "lightfield.summary.secondary.apps", "fixture.viewport"], size: size)
            contains(frames, parent: "lightfield.summary", child: "lightfield.summary.primary")
            contains(frames, parent: "lightfield.summary", child: "lightfield.summary.secondary.apps")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames["lightfield.summary.secondary.apps"]).minX,
                try XCTUnwrap(frames["lightfield.summary.primary"]).maxX - 0.5)
        }
    }

    private func page(module: ReviewFilter, phase: FeatureLightfieldPhase, store: ScanStore) -> some View {
        Group {
            if phase == .running { FeatureDemoRunningFixture(module: module, onCancel: {}) }
            else if module == .uninstall {
                if phase == .landing { AppUninstallScanLandingView(store: store) }
                else { AppUninstallerView(store: store) }
            } else if phase == .landing {
                AppUpdateIdlePage(lastSummary: nil, canScan: true, onScan: {}, onManage: {})
            } else {
                AppUpdateScanSummaryPage(summary: FeatureLightfieldApplicationsFixture.updateSummary(), warnings: [],
                    canManage: true, canRescan: true, onUpdateAll: {}, onManage: {}, onRescan: {})
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.moduleTheme, module.moduleTheme).environment(\.featureLightfieldModule, module)
            .environment(\.featureDisablesLayoutAnimations, true).environment(\.featureDemoElapsedSeconds, 12)
            .transaction { $0.disablesAnimations = true }
    }
    private func makeStore() throws -> ScanStore {
        let defaults = TestPreferenceDomain.make(for: self)
        return try ScanStore.makeForTests(for: self, restoreSavedAccessOperation: {},
            loadScanReadinessSummary: { ScanReadinessSummary(items: []) }, scanHistoryDefaults: defaults,
            menuBarMemoryStatusProvider: { XCTFail("No live provider in B4 fixture"); return MiniWindowDemoData.memorySnapshot },
            menuBarMemoryProcessProvider: { XCTFail("No live provider in B4 fixture"); return MiniWindowDemoData.memorySnapshot },
            cleanupScanOperation: { _, _ in XCTFail("No cleanup in B4 fixture"); throw CancellationError() },
            cleanupPreferences: defaults, cleanReportLoader: { [] }, interruptedOperationReconciler: { [] })
    }
    private func assertEqual(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: 0.5, file: file, line: line)
    }
    private func contains(_ frames: [String: CGRect], parent: String, child: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let container = frames[parent], let content = frames[child] else {
            XCTFail("Missing \(parent) or \(child)", file: file, line: line); return
        }
        XCTAssertTrue(container.insetBy(dx: -0.5, dy: -0.5).contains(content), "\(child) \(content) crosses \(parent) \(container)", file: file, line: line)
    }
}
private final class LightfieldApplicationCallbacks {
    var reviewCount = 0
    var previewCount = 0
    var scanCount = 0
    var historyCount = 0
}
#endif
