import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SpaceMapTreemapPainterTests: XCTestCase {
    typealias Painter = SpaceMapTreemapPainter
    typealias Tile = SpaceMapTreemapLayout.Tile

    private func entry(_ name: String = "clip.mov", directory: Bool = false, estimated: Bool = false,
                       category: StorageMapContentCategory = .video) -> StorageTreemapEntry {
        .init(id: "/analysis/" + name, title: name, path: "/analysis/" + name, sizeBytes: 100, kind: directory ? "folder" : "file",
              isDirectory: directory, childCount: directory ? 1 : nil, isEstimated: estimated, contentCategory: category)
    }

    private func tile(_ entry: StorageTreemapEntry, depth: Int = 0, frame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 100)) -> Tile {
        .init(kind: .entry(entry), frame: frame, depth: depth, header: nil)
    }

    private var index: StorageMapAnalysisIndex {
        SpaceMapMemoryIndex.make(children: [.directory("node_modules", [.file("module.js", 100)]), .file("package.json", 1)])
    }

    func testFillUsesTheSameFileTypeCategoryAsTheList() {
        for category in StorageMapContentCategory.allCases {
            let decoration = Painter.decoration(for: tile(entry(category: category)), dark: true, purposes: nil)
            XCTAssertEqual(decoration.fill, .category(LightfieldFileCategory.category(category)))
            XCTAssertEqual(decoration.fill.color(dark: true), FeatureLightfieldPalette.fileType(LightfieldFileCategory.category(category)))
        }
    }

    func testDepthLightensMonotonicallyInDarkAppearance() {
        let shades = (0...5).map { Painter.decoration(for: tile(entry(), depth: $0), dark: true, purposes: nil).shade }
        XCTAssertEqual(shades, shades.sorted())
        XCTAssertEqual(shades[1], 0.07, accuracy: 0.0001)
        XCTAssertEqual(shades[3], shades[5])
    }

    func testDepthDarkensMonotonicallyInLightAppearance() {
        let shades = (0...5).map { Painter.decoration(for: tile(entry(), depth: $0), dark: false, purposes: nil).shade }
        XCTAssertEqual(shades, shades.sorted(by: >))
        XCTAssertEqual(shades[1], -0.07, accuracy: 0.0001)
    }

    func testRemaindersAndMergedTailsAreNeutral() {
        let remainder = StorageTreemapEntry(id: "remainder", title: "remaining", path: "", sizeBytes: 10,
            kind: "aggregate", isDirectory: false, role: .unmeasuredRemainder)
        let others = Tile(kind: .others(parentPath: "/analysis", count: 3, bytes: 10), frame: .zero, depth: 0, header: nil)
        XCTAssertEqual(Painter.decoration(for: tile(remainder), dark: true, purposes: nil).fill, .neutral)
        XCTAssertEqual(Painter.decoration(for: others, dark: true, purposes: nil).fill, .neutral)
    }

    func testHatchingRequiresADirectoryAndAReclaimReason() throws {
        let map = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/analysis"))
        XCTAssertTrue(Painter.decoration(for: tile(entry("node_modules", directory: true)), dark: true, purposes: map).hatches)
        XCTAssertFalse(Painter.decoration(for: tile(entry("node_modules/module.js")), dark: true, purposes: map).hatches)
        XCTAssertFalse(Painter.decoration(for: tile(entry("normal", directory: true)), dark: true, purposes: map).hatches)
        XCTAssertFalse(Painter.decoration(for: tile(entry("node_modules", directory: true)), dark: true, purposes: nil).hatches)
    }

    func testWarningDotIsOnlyForEstimatedEntries() {
        XCTAssertTrue(Painter.decoration(for: tile(entry(estimated: true)), dark: true, purposes: nil).estimated)
        XCTAssertFalse(Painter.decoration(for: tile(entry()), dark: true, purposes: nil).estimated)
    }

    func testNeutralTilesRenderAsOpaqueSoftGrayInBothAppearances() throws {
        let remainder = StorageTreemapEntry(id: "remainder", title: "Remaining", path: "", sizeBytes: 10,
            kind: "aggregate", isDirectory: false, role: .unmeasuredRemainder)
        let tiles = [tile(entry("parent", directory: true), frame: CGRect(x: 0, y: 0, width: 120, height: 60)),
            Tile(kind: .others(parentPath: "/analysis", count: 3, bytes: 10),
                 frame: CGRect(x: 0, y: 0, width: 60, height: 60), depth: 1, header: nil),
            tile(remainder, depth: 1, frame: CGRect(x: 60, y: 0, width: 60, height: 60))]
        for dark in [true, false] {
            let bitmap = try render(tiles, dark: dark, size: CGSize(width: 120, height: 60))
            for x in [30, 90] {
                let color = try pixelColor(bitmap, x: x, y: 45)
                XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
                XCTAssertEqual(color.redComponent, CGFloat(dark ? 58 : 232) / 255, accuracy: 0.01)
                XCTAssertEqual(color.greenComponent, CGFloat(dark ? 58 : 232) / 255, accuracy: 0.01)
                XCTAssertEqual(color.blueComponent, CGFloat(dark ? 66 : 238) / 255, accuracy: 0.01)
            }
        }
    }

    func testCheckedBadgeOnlyMarksTheContentItemsOwnCheckedPath() {
        let parent = tile(entry("folder", directory: true))
        let child = tile(entry("folder/child"), depth: 1)
        let remainder = tile(StorageTreemapEntry(id: "remainder", title: "Remaining", path: "", sizeBytes: 10,
            kind: "aggregate", isDirectory: false, role: .unmeasuredRemainder))
        let others = Tile(kind: .others(parentPath: "/analysis", count: 3, bytes: 10), frame: parent.frame, depth: 0, header: nil)
        let checked = Painter.checkedIDs(tiles: [parent, child, remainder, others], paths: ["/analysis/folder", ""])
        XCTAssertNotNil(Painter.checkedBadgeFrame(for: parent, in: parent.frame, checkedIDs: checked))
        for item in [child, remainder, others] {
            XCTAssertNil(Painter.checkedBadgeFrame(for: item, in: item.frame, checkedIDs: checked))
        }
        XCTAssertNil(Painter.checkedBadgeFrame(for: parent, in: parent.frame, checkedIDs: []))
        // Synthetic IDs must not allow neutral blocks to acquire a badge either.
        for item in [remainder, others] {
            XCTAssertNil(Painter.checkedBadgeFrame(for: item, in: item.frame, checkedIDs: [SpaceMapTreemapViewState.id(item)]))
        }
    }

    func testCheckedBadgeRequiresTwentyTwoPointsOnBothSidesAndStaysInset() throws {
        let item = tile(entry())
        let ids: Set<String> = [SpaceMapTreemapViewState.id(item)]
        for size in [CGSize(width: 21.9, height: 100), CGSize(width: 100, height: 21.9), .zero] {
            XCTAssertNil(Painter.checkedBadgeFrame(for: item, in: CGRect(origin: .zero, size: size), checkedIDs: ids))
        }
        for size in [CGSize(width: 22, height: 22), CGSize(width: 150, height: 90)] {
            let frame = CGRect(origin: CGPoint(x: 31, y: 17), size: size)
            let badge = try XCTUnwrap(Painter.checkedBadgeFrame(for: item, in: frame, checkedIDs: ids))
            XCTAssertEqual(badge.size, CGSize(width: 14, height: 14))
            XCTAssertEqual(frame.maxX - badge.maxX, 4)
            XCTAssertEqual(frame.maxY - badge.maxY, 4)
            XCTAssertTrue(frame.contains(badge))
        }
    }

    func testCheckedBadgeIsPaintedAboveDescendants() throws {
        let parent = tile(entry("folder", directory: true), frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        let child = tile(entry("folder/child", category: .image), depth: 1, frame: parent.frame)
        let checked = Painter.checkedIDs(tiles: [parent, child], paths: ["/analysis/folder"])
        let bitmap = try render([parent, child], checked: checked)
        let unmarked = try render([parent, child])
        let badge = try XCTUnwrap(Painter.checkedBadgeFrame(for: parent, in: parent.frame, checkedIDs: checked))
        // Inside the circle, away from its border and white checkmark.
        let x = Int(badge.midX - 1), y = Int(badge.minY + 2)
        let color = try pixelColor(bitmap, x: x, y: y)
        let expected = try XCTUnwrap(NSColor(FeatureLightfieldPalette.accent(.largeFiles)).usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.03)
        XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.03)
        XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.03)
        XCTAssertNotEqual(bitmap.colorAt(x: x, y: y), unmarked.colorAt(x: x, y: y))
    }

    func testWarningDotRendersSevenPointsWithTheAppearanceWarningColor() throws {
        let item = tile(entry(estimated: true), frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        let dot = try XCTUnwrap(Painter.warningFrame(in: item.frame))
        XCTAssertEqual(dot, CGRect(x: 90, y: 1, width: 7, height: 7))
        XCTAssertTrue(item.frame.contains(dot))
        for dark in [true, false] {
            let bitmap = try render([item], dark: dark)
            let color = try pixelColor(bitmap, x: Int(dot.midX), y: Int(dot.midY))
            let palette = FeatureLightfieldPalette.resolve(dark ? .dark : .light)
            let expected = try XCTUnwrap(NSColor(palette.warningColor).usingColorSpace(.sRGB))
            XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.01)
            XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.01)
            XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.01)
            XCTAssertEqual(Painter.markerBorder(dark: dark), (dark ? Color.black : Color.white).opacity(0.35))
        }
    }

    private func render(_ tiles: [Tile], dark: Bool = true, checked: Set<String> = [],
                        size: CGSize = CGSize(width: 100, height: 80)) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: SpaceMapTreemapDrawing(tiles: tiles, layoutKey: drawingKey,
            checkedIDs: checked, dark: dark, displayScale: 1).frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 1
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func pixelColor(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        let raw = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
        // colorAt labels raw channels as calibrated RGB, even for an sRGB bitmap.
        let tagged = NSColor(colorSpace: bitmap.colorSpace,
            components: [raw.redComponent, raw.greenComponent, raw.blueComponent, raw.alphaComponent], count: 4)
        return try XCTUnwrap(tagged.usingColorSpace(.sRGB))
    }

    func testSelectionOutlineIsAlwaysPaintedLast() {
        XCTAssertEqual(Painter.outlines(checked: true, hovered: true, selected: true), [.checked, .hovered, .selected])
        XCTAssertEqual(Painter.outlines(checked: true, hovered: false, selected: true).last, .selected)
        XCTAssertEqual(Painter.outlines(checked: false, hovered: true, selected: true).last, .selected)
    }

    func testCheckedIDsOnlyIncludeTheItemsOwnCheckedPath() {
        let folder = tile(entry("folder", directory: true))
        let child = tile(entry("folder/child"), depth: 1)
        let other = tile(entry("other"))
        let remainder = tile(StorageTreemapEntry(id: "remaining", title: "Remaining", path: "", sizeBytes: 10,
            kind: "aggregate", isDirectory: false, role: .unmeasuredRemainder))
        XCTAssertEqual(Painter.checkedIDs(tiles: [folder, child, other, remainder], paths: ["/analysis/folder", ""]),
                       [SpaceMapTreemapViewState.id(folder)])
        XCTAssertEqual(Painter.checkedIDs(tiles: [folder, child], paths: ["/analysis/folder/child"]),
                       [SpaceMapTreemapViewState.id(child)])
    }

    func testDrawingDecisionsDoNotQuerySelectionForThreeThousandTiles() {
        let tiles = (0..<3_000).map { tile(entry("item-\($0)")) }
        let checked = Painter.checkedIDs(tiles: tiles, paths: ["/analysis/item-7"])
        var calls = 0
        let hover = Painter.hoverPresentation(for: nil, highlightedID: nil, snapshot: hoverSnapshot,
            index: index, purposes: nil, selectionState: { _ in calls += 1; return .available })
        let drawing = SpaceMapTreemapDrawing(tiles: tiles, layoutKey: drawingKey, checkedIDs: checked, hoveredIDs: hover.ids)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(drawing.checkedIDs, ["/analysis/item-7"])
        XCTAssertNil(hover.card)
    }

    func testHoverOnlyQueriesTheCurrentContentTileSelection() {
        var queried: [String] = []
        let hovered = tile(entry("folder/child"), depth: 1)
        let hover = Painter.hoverPresentation(for: hovered, highlightedID: "/analysis/folder", snapshot: hoverSnapshot,
            index: index, purposes: nil, selectionState: { entry in
                queried.append(entry.path)
                return .includedInSelection("folder")
            })
        XCTAssertEqual(queried, ["/analysis/folder/child"])
        XCTAssertEqual(hover.ids, ["/analysis/folder", "/analysis/folder/child"])
        XCTAssertTrue(hover.card?.lines.contains {
            $0.text == FileAnalysisTrashPresentation.checkboxHelp(state: .includedInSelection("folder"))
        } == true)
        let others = Tile(kind: .others(parentPath: "/analysis", count: 10, bytes: 100), frame: .zero, depth: 0, header: nil)
        _ = Painter.hoverPresentation(for: others, highlightedID: nil, snapshot: hoverSnapshot,
            index: index, purposes: nil, selectionState: { _ in queried.append("unexpected"); return .available })
        XCTAssertEqual(queried.count, 1)
    }

    private var drawingKey: SpaceMapTreemapSource.Key {
        .init(path: "/analysis", size: CGSize(width: 600, height: 400), levels: 3, version: 1)
    }

    private var hoverSnapshot: StorageMapDirectorySnapshot {
        .init(path: "/analysis", title: "Root", entries: [entry()], measuredBytes: 200, referenceBytes: 1_000,
              inspectedItemCount: 2, omittedEntryCount: 0, isComplete: true)
    }

    func testDrawingEqualityForIdenticalInputs() {
        let tiles = [tile(entry())]
        let first = SpaceMapTreemapDrawing(tiles: tiles, layoutKey: drawingKey)
        let second = SpaceMapTreemapDrawing(tiles: tiles, layoutKey: drawingKey)
        XCTAssertEqual(first, second)
    }

    func testDrawingEqualityChangesWithEveryPaintInput() {
        let tiles = [tile(entry())]
        let first = SpaceMapTreemapDrawing(tiles: tiles, layoutKey: drawingKey)
        let changes: [(inout SpaceMapTreemapDrawing) -> Void] = [
            { $0.hoveredIDs = ["/analysis/clip.mov"] }, { $0.checkedIDs = ["/analysis/clip.mov"] },
            { $0.viewport = .init(scale: 2, origin: CGPoint(x: 20, y: 10)) },
            { $0.selectedID = "/analysis/clip.mov" }, { $0.classificationVersion = 1 },
            { $0.dark = false }, { $0.displayScale = 1 }, { $0.time = 0.1 },
            { $0.transition = .init(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                                    destination: CGRect(x: 0, y: 0, width: 600, height: 400), started: 1) }
        ]
        for (index, change) in changes.enumerated() {
            var other = first
            change(&other)
            XCTAssertNotEqual(first, other, "Paint input \(index)")
        }
        let newKey = SpaceMapTreemapSource.Key(path: drawingKey.path, size: drawingKey.size, levels: 3, version: 2)
        XCTAssertNotEqual(first, SpaceMapTreemapDrawing(tiles: tiles, layoutKey: newKey))
    }

    func testHoverShareUsesMeasuredBytesJustLikeTheList() throws {
        let snapshot = hoverSnapshot
        let item = try XCTUnwrap(snapshot.entries.first)
        let hover = Painter.hoverPresentation(for: tile(item), highlightedID: nil, snapshot: snapshot,
            index: index, purposes: nil, selectionState: { _ in .available })
        let listShare = Double(item.sizeBytes) / Double(snapshot.measuredBytes)
        XCTAssertEqual(hover.card?.detail, ByteFormat.storageString(item.sizeBytes) + " · " + String(format: "%.1f%%", listShare * 100))
        XCTAssertTrue(hover.card?.detail.contains("50.0%") == true)
    }

    func testHoverFrameUsesMeasuredHeightAndKeepsThePointerOffset() {
        let frame = Painter.hoverFrame(at: CGPoint(x: 100, y: 80), size: CGSize(width: 220, height: 253),
            canvas: CGSize(width: 600, height: 500), avoiding: CGPoint(x: 50, y: 30))
        XCTAssertEqual(frame, CGRect(x: 114, y: 94, width: 220, height: 253))
        let limited = Painter.hoverFrame(at: CGPoint(x: 599, y: 399), size: CGSize(width: 220, height: 900),
            canvas: CGSize(width: 600, height: 400))
        XCTAssertEqual(limited.height, 392)
        XCTAssertTrue(CGRect(x: 4, y: 4, width: 592, height: 392).contains(limited))
    }

    func testClampedHoverCardAvoidsTheTileNameOrigin() {
        let origin = CGPoint(x: 430, y: 250)
        let frame = Painter.hoverFrame(at: CGPoint(x: 599, y: 399), size: CGSize(width: 220, height: 250),
            canvas: CGSize(width: 600, height: 400), avoiding: origin)
        XCTAssertFalse(frame.contains(origin))
        XCTAssertTrue(CGRect(x: 4, y: 4, width: 592, height: 392).contains(frame))
    }

    func testNameTruncationLeavesFittingTextIntact() {
        XCTAssertEqual(Painter.truncatedName("旅行相册.png", width: 200, measure: { CGFloat($0.count * 10) }), "旅行相册.png")
    }

    func testNameTruncationFindsTheLongestFittingPrefixAndEllipsis() {
        let measure: (String) -> CGFloat = { CGFloat($0.count * 10) }
        let text = Painter.truncatedName("旅行剪辑-4K.mov", width: 65, measure: measure)
        XCTAssertEqual(text, "旅行剪辑-…")
        XCTAssertLessThanOrEqual(measure(text), 65)
        XCTAssertGreaterThan(measure("旅行剪辑-4…"), 65)
        XCTAssertEqual(Painter.truncatedName("👨‍👩‍👧‍👦视频素材", width: 25, measure: measure), "👨‍👩‍👧‍👦…")
    }

    func testNameTruncationReturnsEmptyWhenNoWholeCharacterFits() {
        for width: CGFloat in [-1, 0, 5, 15] {
            XCTAssertEqual(Painter.truncatedName("旅行相册.png", width: width, measure: { CGFloat($0.count * 10) }), "")
        }
    }

    private func cacheLabel(width: CGFloat = 65, fontSize: CGFloat = 12,
                            weight: Painter.Label.Weight = .semibold) -> Painter.Label {
        .init(id: "name", clip: CGRect(x: 0, y: 0, width: 200, height: 20),
              nameFrame: CGRect(x: 0, y: 0, width: width, height: 15), sizeFrame: nil,
              name: "旅行剪辑-4K.mov", size: "100 B", fontSize: fontSize, weight: weight, sizeOnRight: false)
    }

    func testNameCacheReusesPointWidthAndIncludesFontAndWeight() {
        let cache = SpaceMapTreemapLabelCache()
        var calls = 0
        func measure(_ text: String) -> CGFloat { calls += 1; return CGFloat(text.count * 10) }
        let first = cache.name(for: cacheLabel(width: 65.2), transitioning: false, measure: measure)
        let measured = calls
        XCTAssertGreaterThan(measured, 0)
        XCTAssertEqual(cache.name(for: cacheLabel(width: 65.9), transitioning: false, measure: measure), first)
        XCTAssertEqual(calls, measured)
        _ = cache.name(for: cacheLabel(fontSize: 11), transitioning: false, measure: measure)
        _ = cache.name(for: cacheLabel(weight: .medium), transitioning: false, measure: measure)
        XCTAssertEqual(cache.count, 3)
    }

    func testTransitionUsesCachedNamesOrClipsWithoutMeasuring() {
        let cache = SpaceMapTreemapLabelCache()
        let label = cacheLabel()
        let measured = cache.name(for: label, transitioning: false, measure: { CGFloat($0.count * 10) })
        var calls = 0
        let measure: (String) -> CGFloat = { calls += 1; return CGFloat($0.count * 10) }
        XCTAssertEqual(cache.name(for: label, transitioning: true, measure: measure), measured)
        let uncached = cacheLabel(width: 40)
        XCTAssertEqual(cache.name(for: uncached, transitioning: true, measure: measure), uncached.name)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(cache.count, 1)
    }

    func testNameCacheClearsWhenItsLimitIsReached() {
        let cache = SpaceMapTreemapLabelCache(limit: 2)
        for width: CGFloat in [40, 50, 60] {
            _ = cache.name(for: cacheLabel(width: width), transitioning: false, measure: { CGFloat($0.count * 10) })
        }
        XCTAssertEqual(cache.count, 1)
    }

    func testLabelsChooseLargestAreasAndStopAtOneHundredFifty() {
        let tiles = (0..<200).map { i in
            tile(entry("item-\(i)"), frame: CGRect(x: 0, y: 0, width: 50 + i, height: 100))
        }
        let labels = Painter.labels(tiles: tiles, viewport: .init(), canvas: CGRect(x: 0, y: 0, width: 900, height: 600))
        XCTAssertEqual(labels.count, 150)
        XCTAssertEqual(labels.first?.name, "item-199")
        XCTAssertEqual(labels.last?.name, "item-50")
    }

    func testLabelFramesStayInsideTheirTileAndHeadersOwnTheirNames() {
        let entry = entry("directory", directory: true)
        let header = CGRect(x: 10, y: 20, width: 200, height: 20)
        let directory = Tile(kind: .entry(entry), frame: CGRect(x: 10, y: 20, width: 200, height: 180), depth: 0, header: header)
        let deep = tile(self.entry("deep"), depth: 1, frame: CGRect(x: 20, y: 50, width: 100, height: 100))
        let labels = Painter.labels(tiles: [directory, deep], viewport: .init(), canvas: CGRect(x: 0, y: 0, width: 900, height: 600))
        for label in labels {
            let ownTile = label.id == entry.id ? directory : deep
            XCTAssertTrue(ownTile.frame.contains(label.clip))
            XCTAssertTrue(label.clip.contains(label.nameFrame))
            if let size = label.sizeFrame { XCTAssertTrue(label.clip.contains(size)) }
        }
        XCTAssertEqual(labels.first?.weight, .semibold)
        XCTAssertEqual(labels.first?.clip, header)
        XCTAssertEqual(labels.last?.weight, .medium)
    }

    func testTinyTilesHaveNoLabelsAndEdgesSnapToPhysicalPixels() {
        XCTAssertTrue(Painter.labels(tiles: [tile(entry(), frame: CGRect(x: 0, y: 0, width: 20, height: 10))],
                                    viewport: .init(), canvas: CGRect(x: 0, y: 0, width: 900, height: 600)).isEmpty)
        let snapped = Painter.snapped(CGRect(x: 0.23, y: 0.27, width: 100.23, height: 50.27), scale: 2)
        for edge in [snapped.minX, snapped.minY, snapped.maxX, snapped.maxY] {
            XCTAssertEqual((edge * 2).rounded(), edge * 2)
        }
    }

    func testContentHoverCardIncludesShareCountTypeReasonAndEstimate() throws {
        let map = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/analysis"))
        let card = Painter.hoverCard(for: tile(entry("node_modules", directory: true, estimated: true, category: .developer)),
            totalBytes: 200, index: index, purposes: map, selection: .available)
        XCTAssertEqual(card.title, "node_modules")
        XCTAssertTrue(card.detail.contains("50.0%"))
        XCTAssertTrue(card.lines.contains { $0.text == L10n.text("1 项", "1 item") })
        XCTAssertTrue(card.lines.contains { $0.text == LightfieldFileCategory.developer.title })
        XCTAssertTrue(card.lines.contains { $0.text == SpaceMapReclaimReason.reinstallableDependencies.title })
        XCTAssertTrue(card.lines.contains { $0.text == L10n.text("估算", "Estimated") })
    }

    func testDirectoryHoverCountUsesEnglishSingularAndPluralAndKeepsChinese() throws {
        for language in [AppLanguage.english, .zhHans] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for count in [0, 1, 2] {
                let index = SpaceMapMemoryIndex.make(children: [
                    .directory("folder", (0..<count).map { .file("file-\($0)", 1) })
                ])
                let card = Painter.hoverCard(for: tile(entry("folder", directory: true)), totalBytes: 100,
                    index: index, purposes: nil, selection: .available)
                let expected = language == .english ? (count == 1 ? "1 item" : "\(count) items") : "\(count) 项"
                XCTAssertEqual(try XCTUnwrap(card.lines.first).text, expected)
            }
        }
    }

    func testBlockedHoverCardUsesTheListHelpAndALock() {
        let state = FileAnalysisTrashSelectionState.blocked(.unreadable)
        let card = Painter.hoverCard(for: tile(entry()), totalBytes: 100, index: index, purposes: nil, selection: state)
        XCTAssertTrue(card.lines.contains { $0.locked && $0.text == FileAnalysisTrashPresentation.checkboxHelp(state: state) })
    }

    func testMergedTailAndRemainderHoverCardsAndCanvasClamping() {
        let more = Tile(kind: .others(parentPath: "/analysis", count: 10, bytes: 100), frame: .zero, depth: 0, header: nil)
        let card = Painter.hoverCard(for: more, totalBytes: 200, index: index, purposes: nil, selection: .available)
        XCTAssertEqual(card.title, Painter.moreTitle(10))
        XCTAssertTrue(card.detail.contains(ByteFormat.storageString(100)))
        let remainder = StorageTreemapEntry(id: "remaining", title: "remaining", path: "", sizeBytes: 200,
                                           kind: "aggregate", isDirectory: false, role: .unmeasuredRemainder)
        let remaining = Painter.hoverCard(for: tile(remainder), totalBytes: 200, index: index, purposes: nil, selection: .available)
        XCTAssertEqual(remaining.title, "remaining")
        XCTAssertEqual(remaining.detail, ByteFormat.storageString(200))
        XCTAssertTrue(remaining.lines.isEmpty)
        let frame = Painter.hoverFrame(at: CGPoint(x: 599, y: 399), size: CGSize(width: 220, height: 140), canvas: CGSize(width: 600, height: 400))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 600, height: 400).contains(frame))
    }

    func testAccessibilitySummaryInChinese() {
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let summary = Painter.accessibilitySummary(title: "影片素材", entries: [entry("原始拍摄"), entry("成片导出.mov")])
        XCTAssertTrue(summary.hasPrefix("影片素材 · 最大的三项："))
        XCTAssertTrue(summary.contains("原始拍摄 " + ByteFormat.storageString(100)))
        XCTAssertTrue(summary.contains("、"))
    }

    func testAccessibilitySummaryInEnglish() {
        let scope = MiniWindowLogicLanguageScope(.english)
        defer { scope.restore() }
        let summary = Painter.accessibilitySummary(title: "Footage", entries: [entry("Capture"), entry("Export.mov")])
        XCTAssertTrue(summary.hasPrefix("Footage · Largest three: "))
        XCTAssertTrue(summary.contains("Export.mov " + ByteFormat.storageString(100)))
        XCTAssertTrue(summary.contains(", "))
    }

    func testThreeThousandTilesRenderOffscreenWithinBudget() throws {
        let tiles = (0..<3_000).map { i in
            tile(entry("item-\(i)"), depth: i % 3,
                 frame: CGRect(x: (i % 60) * 20, y: (i / 60) * 16, width: 19, height: 15))
        }
        var elapsed: TimeInterval = 0
        for _ in 0..<10 {
            let start = Date.timeIntervalSinceReferenceDate
            let key = SpaceMapTreemapSource.Key(path: "/analysis", size: CGSize(width: 1_200, height: 800), levels: 3, version: 1)
            let renderer = ImageRenderer(content: SpaceMapTreemapDrawing(tiles: tiles, layoutKey: key).frame(width: 1_200, height: 800))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 1_200)
            elapsed += Date.timeIntervalSinceReferenceDate - start
        }
        let milliseconds = elapsed / 10 * 1_000
        print(String(format: "SpaceMapTreemapDrawing 3000 tiles, 1200x800, 10-run mean: %.3f ms", milliseconds))
        XCTAssertLessThan(milliseconds, 100)
    }

    func testNewSourcesContainNoFileMutationOrProcessEntryPoints() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = [
            "Features/SpaceMap/Treemap/SpaceMapTreemapViewState.swift", "Features/SpaceMap/Treemap/SpaceMapTreemapSource.swift",
            "Views/CareStudio/SpaceMapTreemapPainter.swift", "Views/CareStudio/SpaceMapTreemapView.swift", "Views/CareStudio/SpaceMapTreemapInputBridge.swift"
        ]
        for path in paths {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
            for banned in ["FileManager", "unlink", "removefile", "trashItem", "removeItem", "moveItem", "recycle", "rename(", "Process(", "NSAppleScript"] {
                XCTAssertFalse(source.contains(banned), "\(path): \(banned)")
            }
        }
    }
}
