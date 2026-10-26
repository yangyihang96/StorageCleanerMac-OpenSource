#if DEBUG
import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FeatureLightfieldApplicationP2Tests: XCTestCase {
    private let windows: [CGSize] = [.init(width: 820, height: 560), .init(width: 1000, height: 700),
        .init(width: 1280, height: 763), .init(width: 1680, height: 1050), .init(width: 2400, height: 1350),
        .init(width: 677, height: 390), .init(width: 1280, height: 390)]

    func testInlineMetricGlyphsAreCompleteAcrossSevenWindowsLanguagesSchemesAnd400PointDetail() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let normal = AppUpdateLightfieldPresentation(summary: FeatureLightfieldApplicationsFixture.updateSummary()).metrics
            let long = normal.map { LightfieldMetric(id: $0.id, label: $0.label, value: "12345678901234567890", status: $0.status) }
            let widths = Set(windows.flatMap { window -> [CGFloat] in
                let canvas = CGSize(width: window.width - 210, height: window.height - 28)
                return [FeatureLightfieldGeometry(size: canvas, phase: .landing).content.width,
                        FeatureLightfieldGeometry(size: canvas, phase: .result).content.width]
            } + [FeatureLightfieldGeometry(size: CGSize(width: 400, height: 640), phase: .landing).content.width])
            for dark in [true, false] {
                for metrics in [normal, long] {
                    let root = LightfieldMetricGroup(metrics: metrics, style: .inline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    let host = CalibrationAppKitLayoutHost(root: root, size: CGSize(width: 878, height: 420), dark: dark)
                    defer { host.close() }
                    let required = Set(["fixture.viewport", "lightfield.metrics"] + metrics.flatMap { metric in
                        ["column", "label", "value"].map { "lightfield.metrics." + $0 + "." + metric.id }
                    })
                    for width in widths.sorted() {
                        let size = CGSize(width: width, height: 420)
                        host.resize(to: size)
                        let frames = try await host.frames(required: required, size: size)
                        let group = try XCTUnwrap(frames["lightfield.metrics"])
                        XCTAssertTrue(try XCTUnwrap(frames["fixture.viewport"]).insetBy(dx: -0.5, dy: -0.5).contains(group))
                        var columns = [CGRect]()
                        for metric in metrics {
                            let column = try XCTUnwrap(frames["lightfield.metrics.column." + metric.id])
                            XCTAssertTrue(group.insetBy(dx: -0.5, dy: -0.5).contains(column))
                            assertCompleteGlyphs(NSAttributedString(string: metric.label, attributes: [.font: NSFont.systemFont(ofSize: 13)]),
                                textFrame: try XCTUnwrap(frames["lightfield.metrics.label." + metric.id]), column: column)
                            assertCompleteGlyphs(NSAttributedString(string: metric.value,
                                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)]),
                                textFrame: try XCTUnwrap(frames["lightfield.metrics.value." + metric.id]), column: column)
                            columns.append(column)
                        }
                        for index in columns.indices {
                            for other in columns.indices where other > index { XCTAssertFalse(columns[index].intersects(columns[other])) }
                        }
                        if metrics == normal && width == 878 {
                            XCTAssertEqual(group.height, 48, accuracy: 0.5, "Frozen full-width statistics stay on one row")
                        }
                        if width == 352 {
                            XCTAssertGreaterThan(group.height, 48, "400 pt detail must add rows instead of shrinking Authorization")
                        }
                        try await host.waitForAccessibility(labels: metrics.map { $0.label + " · " + $0.value + " " })
                    }
                }
            }
        }
    }

    func testInlineMetricSourceNeverScalesTruncatesOrClipsText() throws {
        let source = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift")
        let group = try r2SourceDeclaration("struct LightfieldMetricGroup: View", in: source)
        let inline = group.components(separatedBy: "private var stackedMetrics")[0]
        for forbidden in ["minimumScaleFactor", "truncationMode", "lineLimit", "clipped", "max(8", "fontSize"] {
            XCTAssertFalse(inline.contains(forbidden), forbidden)
        }
        XCTAssertTrue(inline.contains(".system(size: 24, weight: .semibold)"))
        XCTAssertTrue(inline.contains(".system(size: 13)"))
        XCTAssertEqual(inline.components(separatedBy: ".fixedSize()").count - 1, 2)
    }

    func testUninstallHeaderAndRowsShareColumnEdgesAcrossSevenWindowsLanguagesAndSchemes() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            for dark in [true, false] {
                for window in windows {
                    let canvas = CGSize(width: window.width - 210, height: window.height - 28)
                    let size = CGSize(width: FeatureLightfieldGeometry(size: canvas, phase: .result).content.width, height: 300)
                    let root = VStack(spacing: 0) {
                        LightfieldApplicationListHeader(kind: .uninstall)
                        FeatureLightfieldUninstallList(apps: FeatureLightfieldApplicationsFixture.uninstallApps,
                            selectedID: nil, select: { _ in }, review: { _ in })
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .environment(\.featureDisablesLayoutAnimations, true)
                    let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: dark)
                    defer { host.close() }
                    let parts = ["leading", "nameColumn", "detailColumn", "trailingColumn"]
                    let required = Set(["fixture.viewport", "lightfield.uninstall.header", "lightfield.uninstall.item.0"] + parts.flatMap {
                        ["lightfield.uninstall.header." + $0, "lightfield.uninstall.item.0." + $0]
                    })
                    let frames = try await host.frames(required: required, size: size)
                    XCTAssertEqual(try XCTUnwrap(frames["lightfield.uninstall.header"]).height, 28, accuracy: 0.5)
                    XCTAssertEqual(try XCTUnwrap(frames["lightfield.uninstall.header"]).maxY,
                        try XCTUnwrap(frames["lightfield.uninstall.item.0"]).minY, accuracy: 0.5)
                    for part in parts {
                        let header = try XCTUnwrap(frames["lightfield.uninstall.header." + part])
                        let row = try XCTUnwrap(frames["lightfield.uninstall.item.0." + part])
                        XCTAssertEqual(header.minX, row.minX, accuracy: 0.5, part)
                        XCTAssertEqual(header.maxX, row.maxX, accuracy: 0.5, part)
                    }
                }
            }
        }
    }

    func testProductionUninstallResultIncludesApprovedHeaderBeforeRows() throws {
        // D14x (2.0.1, CleanMyMac uninstaller): the result moved from
        // `AppUninstallerView.resultContent` (controls `lightfieldResultControls`,
        // rows `lightfieldResultRows(presentation:)`) to the manager page; the
        // order toolbar → approved header → rows is unchanged.
        // D154: the manager is CleanMyMac's light panel. Its header row holds
        // the search and sort controls, the approved column header stays
        // above the scrolling rows, so the order is still controls → header → rows.
        let source = try text("Sources/StorageCleanerMac/Views/ApplicationsManager/ApplicationsManagerView.swift")
        let page = try r2SourceDeclaration("struct ApplicationsManagerView: View", in: source)
        let manager = try r2SourceDeclaration("private var manager", in: page)
        XCTAssertTrue(manager.contains("CareStudioManagerChrome("))
        XCTAssertTrue(manager.contains("query: $model.searchText"))
        XCTAssertTrue(manager.contains("sortOptions: ApplicationSortMode.allCases"))
        XCTAssertTrue(manager.contains("content: { managerList(entries) }"))
        let list = try r2SourceDeclaration("private func managerList", in: page)
        XCTAssertEqual(page.components(separatedBy: "LightfieldApplicationListHeader(kind: .uninstall)").count - 1, 1)
        let header = try XCTUnwrap(list.range(of: "LightfieldApplicationListHeader(kind: .uninstall)"))
        let scroll = try XCTUnwrap(list.range(of: "ScrollView(.vertical)", range: header.upperBound..<list.endIndex))
        XCTAssertNotNil(list.range(of: "rows(entries)", range: scroll.upperBound..<list.endIndex))
        // The lazy rows are the whole scroll document (their own estimate).
        XCTAssertFalse(list.contains("pinnedViews"))
        let chrome = try text("Sources/StorageCleanerMac/Views/CareStudio/CareStudioManagerChrome.swift")
        let stack = try XCTUnwrap(chrome.range(of: "VStack(spacing: 0) {"))
        let controls = try XCTUnwrap(chrome.range(of: "header", range: stack.upperBound..<chrome.endIndex))
        let content = try XCTUnwrap(chrome.range(of: "content", range: controls.upperBound..<chrome.endIndex))
        XCTAssertLessThan(controls.lowerBound, content.lowerBound)
        let component = try text("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldApplicationRows.swift")
        for label in ["应用 / 版本", "应用路径", "可审阅大小", "App / Version", "Application Path", "Size to Review"] {
            XCTAssertTrue(component.contains("\"" + label + "\""))
        }
    }

    private func assertCompleteGlyphs(_ text: NSAttributedString, textFrame: CGRect, column: CGRect,
                                     file: StaticString = #filePath, line: UInt = #line) {
        // Shape the complete string independently at the required readable
        // font, then compare against intrinsic native Text probes. A bounded
        // outer frame or complete AX label alone cannot satisfy this check.
        XCTAssertFalse(text.string.contains("…"), file: file, line: line)
        XCTAssertFalse(text.string.contains("..."), file: file, line: line)
        let shaped = CTLineCreateWithAttributedString(text)
        let width = CGFloat(CTLineGetTypographicBounds(shaped, nil, nil, nil))
        XCTAssertLessThanOrEqual(ceil(width), column.width + 0.5, text.string, file: file, line: line)
        XCTAssertEqual(textFrame.width, ceil(width), accuracy: 1, "Intrinsic glyph probe: " + text.string, file: file, line: line)
        XCTAssertTrue(column.insetBy(dx: -0.5, dy: -0.5).contains(textFrame), text.string, file: file, line: line)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: textFrame.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 1
        container.lineBreakMode = .byTruncatingTail
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let glyphs = manager.glyphRange(for: container)
        XCTAssertEqual(glyphs.length, manager.numberOfGlyphs, "Every source glyph must fit: " + text.string, file: file, line: line)
        if glyphs.length > 0 {
            XCTAssertEqual(manager.truncatedGlyphRange(inLineFragmentForGlyphAt: glyphs.location).location, NSNotFound,
                "No rendered ellipsis: " + text.string, file: file, line: line)
        }
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path), encoding: .utf8)
    }
}
#endif
