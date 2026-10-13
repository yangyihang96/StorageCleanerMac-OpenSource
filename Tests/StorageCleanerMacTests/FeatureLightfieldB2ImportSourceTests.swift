import Foundation
import XCTest

/// Independent guards retained from the committed B2 component tests. App
/// gallery routing and packager changes remain owned by the parent UI batch.
final class FeatureLightfieldB2ImportSourceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
    func testNewComponentSourcesHaveNoContainerOrParallelStyleSystem() throws {
        for name in ["FeatureLightfieldComponents.swift", "FeatureLightfieldCharts.swift", "FeatureLightfieldChartGeometry.swift"] {
            let value = try text("Sources/StorageCleanerMac/Views/DesignSystem/" + name)
            for forbidden in ["Material", ".glassEffect", ".glassPanel", "SurfaceBackground(", "NSWorkspace.shared", "UserDefaults", "Color(hex:"] {
                XCTAssertFalse(value.contains(forbidden), name + " " + forbidden)
            }
            XCTAssertNil(value.range(of: #"RoundedRectangle\([^)]*\)\s*\.fill\("#, options: .regularExpression), name)
            XCTAssertNil(value.range(of: #"0x[0-9a-fA-F]{6}"#, options: .regularExpression), "Use D67 colors: " + name)
        }
    }
    func testTrendGesturesAndBubbleHoverHaveIdentityCallbacks() throws {
        let source = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldCharts.swift")
        XCTAssertTrue(source.contains(".onContinuousHover { phase in"))
        XCTAssertTrue(source.contains("case .ended: setHover(nil)"))
        XCTAssertTrue(source.contains(".gesture(DragGesture(minimumDistance: 0).onChanged"))
        XCTAssertTrue(source.contains("end: current, samples: samples)"))
        XCTAssertTrue(source.contains("onSelection(selection)"))
        XCTAssertTrue(source.contains("onHoverIndex(index)"))
        XCTAssertTrue(source.contains("if hovering { highlighted = item.id; onHighlight(item.id) }"))
        XCTAssertTrue(source.contains("Button { onDrillDown(item.id) }"))
        XCTAssertTrue(source.contains(".buttonStyle(FeatureLightfieldRowButtonStyle(circular: true))"))
        XCTAssertTrue(source.contains("value: highlighted == item.id"))
        XCTAssertTrue(source.contains("diameter >= LightfieldBubbleLayout.labelThreshold"))
        // Review P2-4: a segmented bar animates only the current cell's view.
        let components = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift")
        let bar = try r2SourceDeclaration("struct LightfieldDataBar: View", in: components)
        XCTAssertEqual(bar.components(separatedBy: "LightfieldBarPulse(").count - 1, 0, "No per-cell/whole-track pulse")
        XCTAssertTrue(bar.contains("if breathing.contains(index) {"))
        XCTAssertTrue(bar.contains("LightfieldBreathingCell(instant: reduceMotion || disablesAnimations)"))
        // Review P2-3/P2-7: hover state lives in each bubble (the chart body,
        // which owns the cached layout, never changes on hover); icons are
        // requested at their drawn size so 32 pt loads the 84 px export.
        let chart = try r2SourceDeclaration("struct LightfieldBubbleChart: View", in: source)
        XCTAssertFalse(chart.contains("highlighted"), "Hover must not invalidate the chart/layout")
        XCTAssertTrue(chart.contains("layoutCache.placements(values: values, size: proxy.size)"))
        XCTAssertTrue(source.contains("LightfieldOptionIconView(icon: item.icon, pointSize: iconSide)"))
    }
    func testCenterTextScalingMetricsPathsAndSummaryBaselineCannotRegress() throws {
        let source = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift")
        XCTAssertTrue(source.contains("LightfieldRingTypography(geometry: geometry"))
        let ring = try r2SourceDeclaration("struct LightfieldRing: View", in: source)
        for field in ["typography.valueSize", "typography.unitSize", "typography.labelSize"] {
            XCTAssertTrue(ring.contains(field), "The fitted baseline supplies every font")
        }
        XCTAssertEqual(ring.components(separatedBy: ".minimumScaleFactor(0.1)").count - 1, 3)
        XCTAssertFalse(ring.contains(".minimumScaleFactor(0.8)"), "D69 measures the whole baseline before rendering")
        XCTAssertTrue(source.contains(".frame(width: geometry.textBounds.width, height: geometry.textBounds.height)"))
        XCTAssertTrue(source.contains(".lineLimit(1).truncationMode(.middle).help(path)"))
        XCTAssertTrue(source.contains(".frame(width: width, alignment: .leading)"))
        XCTAssertTrue(source.contains("HStack(alignment: .firstTextBaseline, spacing: 12)"))
        // Main-session visual round: the approved energy/memory renders put
        // secondary metrics at the trailing edge (label over value), not on the
        // primary baseline; geometry is asserted in FeatureLightfieldComponentTests.
        // D72 adds fixed 196 pt score columns with a 24 pt gap. The default
        // remains the imported B2 34 pt spacing for energy/memory summaries.
        XCTAssertTrue(source.contains("var secondaryColumnWidth: CGFloat? = nil"))
        XCTAssertTrue(source.contains("HStack(alignment: .top, spacing: secondaryColumnWidth == nil ? 34 : 24)"))
        XCTAssertTrue(source.contains(".padding(.leading, FeatureLightfield.childRowIndent)"))
    }
    func testMetricLayoutUsesNativeGlyphMeasurementsAndNoParallelStyleSystem() throws {
        let source = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldMetricLayout.swift")
        XCTAssertTrue(source.contains("$0.sizeThatFits(.unspecified).width"))
        XCTAssertTrue(source.contains("count.isMultiple(of: columns)"))
        XCTAssertTrue(source.contains("[.firstTextBaseline]"))
        for forbidden in [".minimumScaleFactor", ".lineLimit", "Color(", "Material", "UserDefaults"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
    func testComponentGalleryIsStrictlyDebugOnlyAndInert() throws {
        let source = try text("Sources/StorageCleanerMac/Debug/LightfieldComponentGallery.swift")
        XCTAssertTrue(source.hasPrefix("#if DEBUG\n"))
        XCTAssertTrue(source.hasSuffix("#endif\n"))
        XCTAssertFalse(source.contains("#if DEBUG || STORAGE_CLEANER_BETA"))
        XCTAssertTrue(source.contains("FeatureLightfieldPage(module:"))
        XCTAssertTrue(source.contains("--debug-lightfield-gallery"))
        for forbidden in ["ScanStore", "UserDefaults", "startScan(", "requestCleanup", "requestUninstall", "NSWorkspace.shared"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}
