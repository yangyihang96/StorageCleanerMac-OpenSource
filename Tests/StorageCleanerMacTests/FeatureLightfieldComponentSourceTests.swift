import Foundation
import XCTest

/// Also runs in Release. Strict DEBUG guard tracking excludes Beta fixtures.
final class FeatureLightfieldComponentSourceTests: XCTestCase {
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
    func testGalleryAndAllReferencesAreStrictlyDebugOnly() throws {
        let gallery = try text("Sources/StorageCleanerMac/Debug/LightfieldComponentGallery.swift")
        XCTAssertTrue(gallery.hasPrefix("#if DEBUG\n"))
        XCTAssertTrue(gallery.hasSuffix("#endif\n"))
        XCTAssertFalse(gallery.contains("#if DEBUG || STORAGE_CLEANER_BETA"))
        for path in ["Debug/LightfieldComponentGallery.swift", "Debug/MainWindowSnapshotPipeline.swift", "Support/MiniWindowDemoData.swift", "Views/ContentView.swift"] {
            var conditions: [String] = []
            var refs = 0
            for line in try text("Sources/StorageCleanerMac/" + path).components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if ") { conditions.append(String(trimmed.dropFirst(4))); continue }
                if trimmed == "#endif" { XCTAssertFalse(conditions.isEmpty); if !conditions.isEmpty { conditions.removeLast() }; continue }
                if trimmed == "#else", !conditions.isEmpty { conditions[conditions.count - 1] = "else"; continue }
                if trimmed.hasPrefix("#elseif "), !conditions.isEmpty { conditions[conditions.count - 1] = String(trimmed.dropFirst(8)); continue }
                if line.contains("LightfieldComponentGallery") || line.contains("captureLightfieldGallery") {
                    refs += 1
                    XCTAssertTrue(conditions.contains("DEBUG"), path + ": " + line)
                }
            }
            XCTAssertGreaterThan(refs, 0, path)
            XCTAssertTrue(conditions.isEmpty, path)
        }
    }
    func testGalleryCaptureNamesInertModeAndArgumentAreWired() throws {
        let gallery = try text("Sources/StorageCleanerMac/Debug/LightfieldComponentGallery.swift")
        let pipeline = try text("Sources/StorageCleanerMac/Debug/MainWindowSnapshotPipeline.swift")
        let demo = try text("Sources/StorageCleanerMac/Support/MiniWindowDemoData.swift")
        let content = try text("Sources/StorageCleanerMac/Views/ContentView.swift")
        XCTAssertTrue(gallery.contains("--debug-lightfield-gallery"))
        XCTAssertTrue(pipeline.contains("capture(named: \"gallery-\\(component).png\", in: directory)"))
        XCTAssertTrue(pipeline.contains("await captureLightfieldGallery(in: directory)"))
        XCTAssertTrue(demo.contains("if LightfieldComponentGallery.isRequested { return true }"))
        XCTAssertTrue(content.contains("LightfieldComponentGallery(session: .shared)"))
        for forbidden in ["ScanStore", "UserDefaults", "startScan(", "requestCleanup", "requestUninstall", "NSWorkspace.shared"] {
            XCTAssertFalse(gallery.contains(forbidden), forbidden)
        }
    }
    func testBothPackagersAddPNGWithoutReplacingHEICRules() throws {
        for path in ["script/build_and_run.sh", "script/make_release_dmg.sh"] {
            let script = try text(path)
            XCTAssertTrue(script.contains("\"$ROOT_DIR\"/Resources/Art/*.heic"), path)
            XCTAssertTrue(script.contains("\"$ROOT_DIR\"/Resources/Art/opt-*.png"), path)
            XCTAssertTrue(script.contains("\"$ROOT_DIR\"/Resources/Art/scope-cleanup-*.png"), "D77 scope exports: " + path)
            // The inventory is read only by tests; it is not shipped (review P2-6).
            XCTAssertFalse(script.contains("lightfield-options.json"), path)
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
        XCTAssertTrue(source.contains(".minimumScaleFactor(0.1)"))
        XCTAssertFalse(source.contains(".minimumScaleFactor(0.8)"), "D69 fits the number and unit as a single baseline")
        XCTAssertTrue(source.contains(".frame(width: geometry.textBounds.width, height: geometry.textBounds.height)"))
        XCTAssertTrue(source.contains(".lineLimit(1).truncationMode(.middle).help(path)"))
        XCTAssertTrue(source.contains(".frame(width: width, alignment: .leading)"))
        XCTAssertTrue(source.contains("HStack(alignment: .firstTextBaseline, spacing: 12)"))
        // Main-session visual round: the approved energy/memory renders put
        // secondary metrics at the trailing edge (label over value), not on the
        // primary baseline; geometry is asserted in FeatureLightfieldComponentTests.
        XCTAssertTrue(source.contains("HStack(alignment: .top, spacing: 34)"))
        XCTAssertTrue(source.contains(".padding(.leading, FeatureLightfield.childRowIndent)"))
    }
}
