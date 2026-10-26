#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FeatureLightfieldFilesContractTests: XCTestCase {
    private let windows: [CGSize] = [.init(width: 820, height: 560), .init(width: 1000, height: 700),
        .init(width: 1280, height: 763), .init(width: 1680, height: 1050), .init(width: 2400, height: 1350),
        .init(width: 677, height: 390), .init(width: 1280, height: 390)]
    private let pages: [(ReviewFilter, Bool)] = [(.largeFiles, false), (.migration, false), (.duplicates, false), (.duplicates, true)]

    func testFourFilePagesKeepSkeletonAcrossThreeStatesSevenWindowsAndTwoSchemes() async throws {
        for dark in [false, true] {
            for (module, similar) in pages {
                // Result fixtures are value-only: validate their rendered
                // contract before a Store fixture can be blocked by HOME.
                // All three phases, pages, sizes and schemes remain covered.
                let phases = [FeaturePresentationDemo.Phase.result]
                    + FeaturePresentationDemo.Phase.allCases.filter { $0 != .result }
                for phase in phases {
                    let root = try fixture(module: module, similar: similar, phase: phase)
                    let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1070, height: 735), dark: dark)
                    defer { host.close() }
                    for window in windows {
                        let canvas = CGSize(width: window.width - 210, height: window.height - 28)
                        host.resize(to: canvas)
                        let frames = try await host.frames(required: ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status", "fixture.viewport"], size: canvas)
                        XCTAssertEqual(try XCTUnwrap(frames["lightfield.primary"]).height, 52, accuracy: 0.5,
                            "Frozen D67 primary height; measured from the rendered button, independent of the layout token")
                        try assertSkeleton(frames, module: module, similar: similar, phase: phase, window: window)
                    }
                }
            }
        }
    }

    // The complete three-state test keeps its Store ownership requirement.
    // This value-only matrix also verifies every result when HOME is read-only.
    func testCompletedFilePagesKeepSkeletonAcrossSevenWindowsAndTwoSchemes() async throws {
        for dark in [false, true] {
            for (module, similar) in pages {
                let host = CalibrationAppKitLayoutHost(root: try fixture(module: module, similar: similar, phase: .result),
                    size: .init(width: 1070, height: 735), dark: dark)
                defer { host.close() }
                for window in windows {
                    let canvas = CGSize(width: window.width - 210, height: window.height - 28)
                    host.resize(to: canvas)
                    let frames = try await host.frames(required: ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status", "fixture.viewport"], size: canvas)
                    XCTAssertEqual(try XCTUnwrap(frames["lightfield.primary"]).height, 52, accuracy: 0.5,
                        "Frozen D67 primary height; measured from the rendered button, independent of the layout token")
                    try assertSkeleton(frames, module: module, similar: similar, phase: .result, window: window)
                }
            }
        }
    }

    func testAnalysisThreeSurfacesUseSummaryAndResponsiveColumnsWithinResultViewport() async throws {
        for dark in [false, true] {
            for surface in 0...2 {
                let host = CalibrationAppKitLayoutHost(root: viewport(FeatureLightfieldFileResultFixture(module: .largeFiles, analysisView: surface), module: .largeFiles),
                    size: .init(width: 1070, height: 735), dark: dark)
                defer { host.close() }
                for window in windows {
                    let canvas = CGSize(width: window.width - 210, height: window.height - 28)
                    host.resize(to: canvas)
                    let frames = try await host.frames(required: ["lightfield.content", "lightfield.files.body", "lightfield.analysis.left", "lightfield.analysis.bubbles", "lightfield.summary", "fixture.viewport"], size: canvas)
                    let body = try XCTUnwrap(frames["lightfield.files.body"])
                    let left = try XCTUnwrap(frames["lightfield.analysis.left"])
                    let bubbles = try XCTUnwrap(frames["lightfield.analysis.bubbles"])
                    XCTAssertTrue(body.insetBy(dx: -0.5, dy: -0.5).contains(left))
                    XCTAssertTrue(body.insetBy(dx: -0.5, dy: -0.5).contains(bubbles))
                    XCTAssertEqual(try XCTUnwrap(frames["lightfield.summary"]).height, 76, accuracy: 0.5)
                    if window == CGSize(width: 1280, height: 763) {
                        XCTAssertEqual(left.width, 344, accuracy: 0.5)
                        XCTAssertEqual(bubbles.minX - left.maxX, 24, accuracy: 0.5)
                        XCTAssertEqual(bubbles.width, 510, accuracy: 0.5)
                        XCTAssertEqual(body.height, 299, accuracy: 0.5)
                    }
                }
            }
        }
    }

    func testMigrationLongPathYieldsToActionSlotAndSelectionAXRemainsPressable() async throws {
        let host = CalibrationAppKitLayoutHost(root: viewport(FeatureLightfieldFileResultFixture(module: .migration), module: .migration),
            size: .init(width: 1070, height: 735), dark: true)
        defer { host.close() }
        let id = FeatureLightfieldFileResultFixture.migrationEntries[0].id
        for window in windows {
            let canvas = CGSize(width: window.width - 210, height: window.height - 28)
            host.resize(to: canvas)
            let frames = try await host.frames(required: ["lightfield.migration.row." + id, "lightfield.migration.actions." + id,
                "lightfield.migration.name." + id, "fixture.viewport"], size: canvas)
            let row = try XCTUnwrap(frames["lightfield.migration.row." + id])
            let action = try XCTUnwrap(frames["lightfield.migration.actions." + id])
            let name = try XCTUnwrap(frames["lightfield.migration.name." + id])
            XCTAssertEqual(row.height, 52, accuracy: 0.5)
            XCTAssertTrue(row.insetBy(dx: -0.5, dy: -0.5).contains(action))
            XCTAssertGreaterThanOrEqual(action.width, 52)
            XCTAssertLessThanOrEqual(name.maxX, action.minX - 8)
        }
        host.resize(to: .init(width: 1070, height: 735))
        let current = try await host.frames(required: ["lightfield.migration.select." + id, "fixture.viewport"], size: .init(width: 1070, height: 735))
        let checkFrame = try XCTUnwrap(current["lightfield.migration.select." + id])
        let groupChecks = current.filter { $0.key.hasPrefix("lightfield.migration.group.") && $0.key.hasSuffix(".select") }.map(\.value)
        XCTAssertFalse(groupChecks.isEmpty)
        let label = L10n.text("选择：", "Select: ") + FeatureLightfieldFileResultFixture.migrationEntries[0].item.title
        try await host.waitForAccessibility(labels: [label], expectedValues: [label: L10n.text("未选", "Not selected")], pressLabels: [label], hitTestFrames: [checkFrame])
        XCTAssertTrue(try host.press(label: label))
        try await host.waitForAccessibility(labels: [label], expectedValues: [label: L10n.text("已选", "Selected")], hitTestFrames: [checkFrame])
        let group = L10n.text("选择组：", "Select group: ") + L10n.text("视频", "Videos")
        try await host.waitForAccessibility(labels: [group], expectedValues: [group: L10n.text("部分已选", "Partially selected")], pressLabels: [group], hitTestFrames: groupChecks)
        XCTAssertTrue(try host.press(label: group))
        try await host.waitForAccessibility(labels: [group], expectedValues: [group: L10n.text("已选", "Selected")], hitTestFrames: groupChecks)
    }

    func testAnalysisTypeHighlightAndDirectoryBubblePreserveIdentityThroughAXPress() async throws {
        let host = CalibrationAppKitLayoutHost(root: viewport(FeatureLightfieldFileResultFixture(module: .largeFiles, analysisView: 1), module: .largeFiles),
            size: .init(width: 1070, height: 735), dark: false)
        defer { host.close() }
        let type = try XCTUnwrap(FileLightfieldPresentation.types(FeatureLightfieldFileResultFixture.analysis).first)
        let label = type.label + " · " + type.formattedValue
        try await host.waitForAccessibility(labels: [label], expectedValues: [label: L10n.text("未高亮", "Not highlighted")], pressLabels: [label])
        XCTAssertTrue(try host.press(label: label))
        try await host.waitForAccessibility(labels: [label], expectedValues: [label: L10n.text("已高亮", "Highlighted")])
        let folders = L10n.text("目录", "Folders")
        try await host.waitForAccessibility(labels: [folders], pressLabels: [folders])
        XCTAssertTrue(try host.press(label: folders))
        let entry = try XCTUnwrap(FeatureLightfieldFileResultFixture.analysis.rootSnapshot.entries.first)
        let bubble = entry.title + " · " + ByteFormat.storageString(entry.sizeBytes)
        try await host.waitForAccessibility(labels: [bubble], pressLabels: [bubble])
        XCTAssertTrue(try host.press(label: bubble))
        let breadcrumb = L10n.text("返回目录：", "Return to folder: ") + entry.title
        // As in the B2 production AX tests, discover scroll-hosted controls
        // by their actual frames through public native accessibilityHitTest.
        let current = try await host.frames(required: ["lightfield.analysis.breadcrumb.0", "lightfield.analysis.breadcrumb.1", "fixture.viewport"], size: .init(width: 1070, height: 735))
        let breadcrumbFrames = [try XCTUnwrap(current["lightfield.analysis.breadcrumb.0"]), try XCTUnwrap(current["lightfield.analysis.breadcrumb.1"])]
        let root = L10n.text("返回目录：", "Return to folder: ") + "~"
        try await host.waitForAccessibility(labels: [breadcrumb, root], pressLabels: [breadcrumb, root], hitTestFrames: breadcrumbFrames)
        XCTAssertTrue(try host.press(label: root))
        try await host.waitForAccessibility(labels: [bubble])
    }

    func testDuplicateRowsAndSimilarTilesExposeSelectionKeepAndCollapseWithoutUnsafeCallbacks() async throws {
        for similar in [false, true] {
            let groups = FeatureLightfieldFileResultFixture.duplicateGroups(similar: similar)
            let size = CGSize(width: 878, height: 650)
            let host = CalibrationAppKitLayoutHost(root: FeatureOptionsScrollView(probePrefix: "fixture.duplicates.list",
                balancesContent: false, usesLightfield: true, fadesResults: true) {
                    LightfieldDuplicateAXFixture(groups: groups, similar: similar)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(\.featurePresentationIsFixture, true).environment(\.featureDisablesLayoutAnimations, true), size: size, dark: true)
            defer { host.close() }
            let title = groups[0].title
            let initial = try await host.frames(required: ["lightfield.duplicates.group." + groups[0].id, "fixture.viewport"], size: size)
            let headerFrame = try XCTUnwrap(initial["lightfield.duplicates.group." + groups[0].id])
            try await host.waitForAccessibility(labels: [title], expectedValues: [title: L10n.text("已展开", "Expanded")], pressLabels: [title], hitTestFrames: [headerFrame])
            let item = groups[0].items[1]
            let label = similar ? L10n.text("比对标记：", "Review mark: ") + item.title : L10n.text("选择副本：", "Select copy: ") + item.path
            let checkProbe = (similar ? "lightfield.photos.mark." : "lightfield.duplicates.select.") + item.id
            let controls = try await host.frames(required: [checkProbe, "fixture.viewport"], size: size)
            let checkFrame = try XCTUnwrap(controls[checkProbe])
            try await host.waitForAccessibility(labels: [label], pressLabels: [label], hitTestFrames: [checkFrame])
            XCTAssertTrue(try host.press(label: label))
            try await host.waitForAccessibility(labels: [label], expectedValues: [label: similar ? L10n.text("已标记比对", "Marked for review") : L10n.text("已选", "Selected")], hitTestFrames: [checkFrame])
            let probes = similar ? ["lightfield.photos.tile." + item.id, "lightfield.photos.preview." + item.id] : ["lightfield.duplicates.row." + item.id, "lightfield.duplicates.actions." + item.id]
            let frames = try await host.frames(required: Set(probes + ["fixture.viewport"]), size: size)
            XCTAssertTrue(try XCTUnwrap(frames[probes[0]]).insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(frames[probes[1]])))
            XCTAssertTrue(try host.press(label: title))
            try await host.waitForAccessibility(labels: [title], expectedValues: [title: L10n.text("已折叠", "Collapsed")], hitTestFrames: [headerFrame])
            XCTAssertTrue(try host.press(label: title))
            try await host.waitForAccessibility(labels: [label], hitTestFrames: [checkFrame])
            if !similar {
                let auto = L10n.text("自动选择：保留最新", "Auto Select: Keep Newest")
                let toolbar = try await host.frames(required: ["lightfield.duplicates.auto-select", "fixture.viewport"], size: size)
                try await host.waitForAccessibility(labels: [auto], expectedEnabled: [auto: false],
                    hitTestFrames: [try XCTUnwrap(toolbar["lightfield.duplicates.auto-select"])])
            }
        }
    }

    func testShareBarUsesThreePointsWithoutChangingRatioOrProgressHeights() async throws {
        let size = CGSize(width: 520, height: 100)
        let root = VStack(spacing: 20) {
            LightfieldDataBar(progress: 0.25, module: .largeFiles, style: .share).layoutProbe("share")
            LightfieldDataBar(progress: 0.25, module: .largeFiles).layoutProbe("ratio")
            LightfieldDataBar(progress: 0.25, module: .largeFiles, style: .progress()).layoutProbe("progress")
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.featureDisablesLayoutAnimations, true)
        let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: true)
        defer { host.close() }
        let frames = try await host.frames(required: ["share", "ratio", "progress", "fixture.viewport"], size: size)
        XCTAssertEqual(try XCTUnwrap(frames["share"]).height, 3, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frames["ratio"]).height, 2, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frames["progress"]).height, 6, accuracy: 0.5)
    }

    private func assertSkeleton(_ frames: [String: CGRect], module: ReviewFilter, similar: Bool,
                                phase: FeaturePresentationDemo.Phase, window: CGSize) throws {
        let primary = try XCTUnwrap(frames["lightfield.primary"])
        let content = try XCTUnwrap(frames["lightfield.content"])
        let status = try XCTUnwrap(frames["lightfield.status"])
        let viewport = try XCTUnwrap(frames["fixture.viewport"])
        for frame in [primary, content, status] {
            XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(module)/\(similar)/\(phase)/\(window): \(frame)")
        }
        XCTAssertEqual(primary.height, 52, accuracy: 0.5)
        XCTAssertEqual(status.height, 64, accuracy: 0.5)
        XCTAssertEqual(primary.minY - content.maxY, 24, accuracy: 0.5)
        XCTAssertEqual(status.minY - primary.maxY, 24, accuracy: 0.5)
        if window == CGSize(width: 1280, height: 763) {
            XCTAssertEqual(try XCTUnwrap(frames["lightfield.title"]).minX, 96, accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(frames["lightfield.title"]).minY, 92, accuracy: 0.5)
            assertFrame(content, CGRect(x: 96, y: 176, width: phase == .result ? 878 : 520, height: 395))
            assertFrame(primary, CGRect(x: 96, y: 595, width: 520, height: 52))
            assertFrame(status, CGRect(x: 52, y: 671, width: 966, height: 64))
        }
    }

    private func assertFrame(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, file: file, line: line)
    }
    private func viewport<V: View>(_ view: V, module: ReviewFilter) -> some View {
        AdaptivePageViewport(resetID: module) { view }
            .environment(\.featureLightfieldModule, module).environment(\.featureDisablesLayoutAnimations, true)
            // These are the D67/D70 file pages; the studio's Space Lens has its own review (D154 batch 3G).
            .environment(\.careStudioClassicResults, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transaction { $0.disablesAnimations = true }
    }
    private func fixture(module: ReviewFilter, similar: Bool, phase: FeaturePresentationDemo.Phase) throws -> AnyView {
        if phase == .result { return AnyView(viewport(FeatureLightfieldFileResultFixture(module: module, isSimilarPhotos: similar), module: module)) }
        let defaults = TestPreferenceDomain.make(for: self)
        let store = try ScanStore.makeForTests(for: self, restoreSavedAccessOperation: {},
            loadScanReadinessSummary: { ScanReadinessSummary(items: []) }, scanHistoryDefaults: defaults,
            menuBarMemoryStatusProvider: { XCTFail("No provider in file-page fixture"); return MiniWindowDemoData.memorySnapshot },
            menuBarMemoryProcessProvider: { XCTFail("No provider in file-page fixture"); return MiniWindowDemoData.memorySnapshot },
            cleanupScanOperation: { _, _ in XCTFail("No cleanup in file-page fixture"); throw CancellationError() },
            cleanupPreferences: defaults, cleanReportLoader: { [] }, interruptedOperationReconciler: { [] })
        let session = FeaturePresentationDemo(); session.phase = phase
        let health = ComputerHealthStore(probe: LightfieldFilesInertProbe(), batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController())
        return AnyView(viewport(FeaturePresentationDemoView(session: session, store: store, module: module,
            healthStore: health, networkStore: NetworkSpeedTestStore(), browserStore: BrowserPrivacyStore(), isSimilarPhotosOverride: similar), module: module))
    }
}
private struct LightfieldFilesInertProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot { XCTFail("No hardware reads in file-page fixture"); throw CancellationError() }
}
private struct LightfieldDuplicateAXFixture: View {
    let groups: [DuplicateDisplayGroup]
    let similar: Bool
    @State private var selected: Set<String> = []
    var body: some View {
        DuplicateLightfieldBody(groups: groups, isSimilarPhotos: similar, selectedIDs: selected,
            onSelected: { value, item in if value { selected.insert(item.id) } else { selected.remove(item.id) } },
            onReveal: { _ in XCTFail("No Finder operation in AX fixture") }, onCopyPath: { _ in XCTFail("No clipboard write in AX fixture") })
    }
}
#endif
