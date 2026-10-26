#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SpaceMapTreemapWindowTests: XCTestCase {
    private typealias Bridge = SpaceMapTreemapInputBridge.InputView
    private typealias Tile = SpaceMapTreemapLayout.Tile

    @MainActor private final class Records: ObservableObject {
        @Published var busy = false
        var opened: [StorageTreemapEntry] = []
        var toggled: [StorageTreemapEntry] = []
        var breadcrumbs: [Int] = []
        var forwards = 0
        var frames: [String: CGRect] = [:]
        var setStyle: ((SpaceMapViewStyle) -> Void)?
        var setSurface: ((Int) -> Void)?
    }

    /// Keep this host independent of the app store: each callback records its
    /// argument and only changes inert values from the completed demo index.
    private struct Host: View {
        let result: StorageMapAnalysisResult
        @ObservedObject var records: Records
        @State private var navigation: [StorageMapDirectorySnapshot]
        @State private var selections: Set<String> = []
        @State private var style: SpaceMapViewStyle
        @State private var surface = 0

        init(result: StorageMapAnalysisResult, records: Records, style: SpaceMapViewStyle = .blocks, nested: Bool = false) {
            self.result = result
            self.records = records
            _style = State(initialValue: style)
            var levels = [result.rootSnapshot]
            if nested, let child = try? DiskScanner(excludedPaths: []).storageMapSnapshot(
                at: result.index.rootPath + "/影片素材", using: result.index) { levels.append(child) }
            _navigation = State(initialValue: levels)
        }

        var body: some View {
            MainContentHost(route: .largeFiles, showsIntegratedTitlebar: false) {
                CareStudioSpaceLensPage(result: result, navigation: navigation,
                    types: FileLightfieldPresentation.types(result), largest: FileLightfieldPresentation.largest(result.index),
                    fileCount: FileLightfieldPresentation.fileCount(result.index), surface: $surface, mapStyle: $style, mapColorMode: .constant(.type),
                    isBusy: records.busy, checkedPaths: selections, selectionState: { entry in
                        result.index.blockedDirectoryPaths.contains(entry.path) ? .blocked(.containsProtectedLocation)
                            : selections.contains(entry.id) ? .selected : .available
                    }, status: L10n.text("演示索引 · 未执行移动", "Demo index · No move performed"),
                    canReview: !selections.isEmpty, onReview: {}, onToggle: { entry in
                        records.toggled.append(entry)
                        if selections.contains(entry.id) { selections.remove(entry.id) } else { selections.insert(entry.id) }
                    }, onOpen: { entry in
                        records.opened.append(entry)
                        guard let base = navigation.last?.path else { return }
                        var paths = [entry.path]
                        var parent = DiskScanner.storageMapParentPath(entry.path)
                        while parent != base {
                            guard parent != "/", parent.hasPrefix(base + "/") else { return }
                            paths.append(parent)
                            parent = DiskScanner.storageMapParentPath(parent)
                        }
                        let scanner = DiskScanner(excludedPaths: [])
                        let snapshots = paths.reversed().compactMap { try? scanner.storageMapSnapshot(at: $0, using: result.index) }
                        if snapshots.count == paths.count { navigation.append(contentsOf: snapshots) }
                    }, onBreadcrumb: { index in
                        records.breadcrumbs.append(index)
                        if navigation.indices.contains(index) { navigation = Array(navigation.prefix(index + 1)) }
                    }, onForward: { records.forwards += 1 })
            }
            .environment(\.featurePresentationIsFixture, true)
            .environment(\.featureDisablesLayoutAnimations, true)
            // SwiftUI builds its accessibility tree only for an assistive
            // client; `press` reads that tree, as V0LayoutHost's does.
            .environment(\.accessibilityEnabled, true)
            .layoutProbe("treemap.test.viewport")
            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                Task { @MainActor in records.frames = frames }
            }
            .onAppear {
                records.setStyle = { style = $0 }
                records.setSurface = { surface = $0 }
            }
            .onDisappear { records.setStyle = nil; records.setSurface = nil }
        }
    }

    private func window(result: StorageMapAnalysisResult = FeatureLightfieldFileResultFixture.analysis,
                        records: Records, size: CGSize = CGSize(width: 1_024, height: 734),
                        style: SpaceMapViewStyle = .blocks, nested: Bool = false, light: Bool = false) -> NSWindow {
        let controller = NSHostingController(rootView: Host(result: result, records: records, style: style, nested: nested)
            .environment(\.colorScheme, light ? .light : .dark))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFront(nil)
        return window
    }

    private func close(_ window: NSWindow) { window.orderOut(nil); window.close() }

    private func settle(_ window: NSWindow, until predicate: () -> Bool = { true }) async throws {
        for step in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
            if step >= 3 && predicate() { return }
        }
        XCTFail("The blocks map did not settle")
    }

    private func bridge(in view: NSView?) -> Bridge? {
        guard let view else { return nil }
        if let bridge = view as? Bridge { return bridge }
        return view.subviews.lazy.compactMap { self.bridge(in: $0) }.first
    }

    private func ready(_ window: NSWindow, path: String? = nil) async throws -> Bridge {
        try await settle(window) {
            guard let bridge = self.bridge(in: window.contentView) else { return false }
            return !bridge.tiles.isEmpty && (path == nil || bridge.path == path)
                && abs(bridge.layoutSize.width - bridge.bounds.width) <= 1
                && abs(bridge.layoutSize.height - bridge.bounds.height) <= 1
        }
        return try XCTUnwrap(bridge(in: window.contentView))
    }

    private func entry(_ tile: Tile) -> StorageTreemapEntry? {
        if case let .entry(entry) = tile.kind { return entry }
        return nil
    }

    private func point(_ tile: Tile, bridge: Bridge) -> CGPoint {
        let rect = bridge.viewport.project(tile.header ?? tile.frame)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func testBlocksAndListFitAboveTheActionAtEverySupportedWindowSize() async throws {
        let records = Records()
        let window = window(records: records)
        defer { close(window) }
        for size in [CGSize(width: 1_024, height: 734), CGSize(width: 760, height: 600),
                     CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
            window.setContentSize(size)
            try await settle(window) {
                guard let viewport = records.frames["treemap.test.viewport"] else { return false }
                return abs(viewport.width - size.width) < 0.5 && abs(viewport.height - size.height) < 0.5
            }
            let list = try XCTUnwrap(records.frames["careStudio.spaceLens.list"])
            let action = try XCTUnwrap(records.frames["careStudio.action"])
            XCTAssertLessThanOrEqual(list.maxY, action.minY + 0.5)
            if size.width >= 680 {
                let blocks = try XCTUnwrap(records.frames["careStudio.spaceLens.blocks"])
                let style = try XCTUnwrap(records.frames["careStudio.spaceLens.mapStyle"])
                XCTAssertLessThanOrEqual(list.maxX, blocks.minX)
                XCTAssertLessThanOrEqual(blocks.maxY, action.minY + 0.5)
                XCTAssertEqual(style.minY, list.minY, accuracy: 1)
            } else {
                XCTAssertNil(records.frames["careStudio.spaceLens.blocks"])
                XCTAssertNil(records.frames["careStudio.spaceLens.mapStyle"])
            }
        }
    }

    func testFullWidthAndSurfaceChangesRestoreTheListAndRememberBlocks() async throws {
        let records = Records()
        let window = window(records: records)
        defer { close(window) }
        _ = try await ready(window)
        let width = try XCTUnwrap(records.frames["careStudio.spaceLens.blocks"]).width
        try press(L10n.text("全宽显示", "Full Width"), in: window)
        try await settle(window) { records.frames["careStudio.spaceLens.list"] == nil }
        XCTAssertGreaterThan(try XCTUnwrap(records.frames["careStudio.spaceLens.blocks"]).width, width)
        XCTAssertLessThanOrEqual(try XCTUnwrap(records.frames["careStudio.spaceLens.blocks"]).maxY,
                                try XCTUnwrap(records.frames["careStudio.action"]).minY + 0.5)
        records.setSurface?(1)
        try await settle(window) { records.frames["careStudio.spaceLens.bubbles"] != nil }
        XCTAssertNotNil(records.frames["careStudio.spaceLens.list"])
        XCTAssertNil(records.frames["careStudio.spaceLens.mapStyle"])
        records.setSurface?(0)
        _ = try await ready(window)
        XCTAssertNotNil(records.frames["careStudio.spaceLens.list"])
        try press(L10n.text("全宽显示", "Full Width"), in: window)
        try await settle(window) { records.frames["careStudio.spaceLens.list"] == nil }
        window.setContentSize(CGSize(width: 604, height: 490))
        try await settle(window) { records.frames["careStudio.spaceLens.blocks"] == nil }
        XCTAssertNotNil(records.frames["careStudio.spaceLens.list"])
        window.setContentSize(CGSize(width: 1_024, height: 734))
        _ = try await ready(window)
        XCTAssertNotNil(records.frames["careStudio.spaceLens.list"])
        records.setStyle?(.bubbles)
        try await settle(window) { records.frames["careStudio.spaceLens.bubbles"] != nil }
        XCTAssertNil(records.frames["careStudio.spaceLens.blocks"])
    }

    func testClickEnterDoubleClickSpaceEscapeForwardAndHoverUsePageCallbacks() async throws {
        let records = Records()
        let window = window(records: records)
        defer { close(window) }
        let map = try await ready(window)
        let directory = try XCTUnwrap(map.tiles.first { $0.depth == 0 && entry($0)?.canDescend == true })
        let folder = try XCTUnwrap(entry(directory))
        map.send(.click(point(directory, bridge: map), count: 1))
        map.send(.key(.activate))
        XCTAssertEqual(records.opened.last?.path, folder.path)
        let child = try await ready(window, path: folder.path)
        let file = try XCTUnwrap(child.tiles.first { entry($0)?.isDirectory == false && entry($0)?.role == .content })
        let fileEntry = try XCTUnwrap(entry(file))
        child.send(.pointer(point(file, bridge: child)))
        try await settle(window)
        let expected = SpaceMapTreemapViewState.highlightedID(for: file,
            roots: try DiskScanner(excludedPaths: []).storageMapSnapshot(at: folder.path, using: FeatureLightfieldFileResultFixture.analysis.index).entries)
        XCTAssertEqual(child.highlightedID, expected)
        XCTAssertNotNil(expected)
        child.send(.click(point(file, bridge: child), count: 2))
        XCTAssertEqual(records.toggled.last?.path, fileEntry.path)
        child.send(.key(.toggle))
        XCTAssertEqual(records.toggled.filter { $0.path == fileEntry.path }.count, 2)
        child.send(.key(.escape))
        XCTAssertEqual(records.breadcrumbs.last, 0)
        _ = try await ready(window, path: FeatureLightfieldFileResultFixture.analysis.index.rootPath)
        window.makeFirstResponder(child)
        let command = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "]", charactersIgnoringModifiers: "]",
            isARepeat: false, keyCode: 30))
        child.keyDown(with: command)
        XCTAssertEqual(records.forwards, 1)
    }

    func testWheelEntersAtCeilingAndMomentumCannotEnterAgain() async throws {
        let records = Records()
        let window = window(records: records)
        defer { close(window) }
        let map = try await ready(window)
        let tile = try XCTUnwrap(map.tiles.first { $0.depth == 0 && entry($0)?.canDescend == true })
        let point = point(tile, bridge: map)
        map.send(.zoom(factor: 20, point: point, phase: .began, momentum: false, time: 1))
        map.send(.zoom(factor: 1.15, point: point, phase: .changed, momentum: false, time: 1.1))
        XCTAssertEqual(records.opened.count, 1)
        let child = try await ready(window, path: try XCTUnwrap(entry(tile)).path)
        child.send(.zoom(factor: 20, point: CGPoint(x: 80, y: 80), phase: .changed, momentum: true, time: 1.2))
        child.send(.zoom(factor: 1.15, point: CGPoint(x: 80, y: 80), phase: .ended, momentum: true, time: 1.3))
        XCTAssertEqual(records.opened.count, 1)
        records.busy = true
        try await settle(window)
        child.send(.key(.toggle)); child.send(.key(.escape)); child.send(.key(.forward))
        XCTAssertTrue(records.toggled.isEmpty)
        XCTAssertTrue(records.breadcrumbs.isEmpty)
        XCTAssertEqual(records.forwards, 0)
    }

    func testHoverCardsFitTheirNaturalContentInBothAppearances() async throws {
        for (language, light) in [(AppLanguage.zhHans, false), (.english, true)] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for scene in ["file", "reclaim", "blocked"] {
                let result = scene == "file" ? FeatureLightfieldFileResultFixture.analysis : try richResult()
                let records = Records()
                let window = window(result: result, records: records, light: light)
                defer { close(window) }
                let map = try await ready(window)
                let tile = try XCTUnwrap(map.tiles.first {
                    switch scene {
                    case "reclaim": self.entry($0)?.title == "node_modules"
                    case "blocked": self.entry($0)?.title == "受保护目录"
                    default: self.entry($0)?.path.contains("/原始拍摄/") == true
                    }
                })
                map.send(.pointer(point(tile, bridge: map)))
                let rowCount = scene == "reclaim" ? 7 : scene == "blocked" ? 6 : 5
                try await waitForHover(window, records: records, rowCount: rowCount)
                let card = try XCTUnwrap(records.frames["careStudio.spaceLens.hoverCard"])
                let canvas = try XCTUnwrap(records.frames["careStudio.spaceLens.blocks"])
                let rows = hoverRows(records)
                let naturalHeight = rows.reduce(CGFloat(24 + (rows.count - 1) * 4)) { $0 + $1.height }
                XCTAssertLessThanOrEqual(card.height, naturalHeight + 2, scene)
                XCTAssertGreaterThanOrEqual(card.height, naturalHeight - 2, scene)
                XCTAssertLessThan(card.height, canvas.height * 0.75, scene)
                XCTAssertTrue(canvas.insetBy(dx: -0.5, dy: -0.5).contains(card), scene)
                for row in rows { XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(row), scene) }
            }
        }
    }

    func testDarkHoverCacheDisplayHasADarkBackgroundAndVisibleText() async throws {
        try await assertHoverBitmap(light: false)
    }

    func testLightHoverCacheDisplayHasALightBackgroundAndVisibleText() async throws {
        try await assertHoverBitmap(light: true)
    }

    private func hoverRows(_ records: Records) -> [CGRect] {
        records.frames.filter { $0.key.hasPrefix("careStudio.spaceLens.hoverCard.") }
            .map(\.value).sorted { $0.minY < $1.minY }
    }

    private func waitForHover(_ window: NSWindow, records: Records, rowCount: Int) async throws {
        try await settle(window) {
            self.hoverRows(records).count == rowCount && (records.frames["careStudio.spaceLens.hoverCard"]?.height ?? 0) > 24
        }
        try await settle(window)
    }

    private func assertHoverBitmap(light: Bool) async throws {
        let scope = MiniWindowLogicLanguageScope(light ? .english : .zhHans)
        defer { scope.restore() }
        let records = Records()
        let window = window(records: records, light: light)
        defer { close(window) }
        let map = try await ready(window)
        let tile = try XCTUnwrap(map.tiles.first { self.entry($0)?.path.contains("/原始拍摄/") == true })
        map.send(.pointer(point(tile, bridge: map)))
        try await waitForHover(window, records: records, rowCount: 5)
        let card = try XCTUnwrap(records.frames["careStudio.spaceLens.hoverCard"])
        let title = try XCTUnwrap(records.frames["careStudio.spaceLens.hoverCard.title"])
        let viewport = try XCTUnwrap(records.frames["treemap.test.viewport"])
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scaleX = CGFloat(bitmap.pixelsWide) / viewport.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / viewport.height
        func pixel(_ point: CGPoint) -> (Int, Int) {
            (Int((point.x - viewport.minX) * scaleX), Int((point.y - viewport.minY) * scaleY))
        }
        func brightness(x: Int, y: Int) throws -> Double {
            let raw = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
            // Preserve the bitmap's profile before converting its raw channels to sRGB.
            let tagged = NSColor(colorSpace: bitmap.colorSpace,
                components: [raw.redComponent, raw.greenComponent, raw.blueComponent, raw.alphaComponent], count: 4)
            let color = try XCTUnwrap(tagged.usingColorSpace(.sRGB))
            return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        }
        let rows = hoverRows(records)
        // Sample the gap nearest the center so text cannot contaminate the background samples.
        let gaps = zip(rows, rows.dropFirst()).map { ($0.maxY + $1.minY) / 2 }
        let sampleY = try XCTUnwrap(gaps.min { abs($0 - card.midY) < abs($1 - card.midY) })
        var backgrounds: [Double] = []
        for offset: CGFloat in [-8, 0, 8] {
            let (x, y) = pixel(CGPoint(x: card.midX + offset, y: sampleY))
            let value = try brightness(x: x, y: y)
            if light { XCTAssertGreaterThan(value, 0.8) }
            else { XCTAssertLessThan(value, 0.35) }
            backgrounds.append(value)
        }
        let background = backgrounds.reduce(0, +) / Double(backgrounds.count)
        let (minX, minY) = pixel(title.origin)
        let (maxX, maxY) = pixel(CGPoint(x: title.maxX, y: title.maxY))
        var contrast: Double = 0
        for y in minY..<maxY {
            for x in minX..<maxX { contrast = max(contrast, abs(try brightness(x: x, y: y) - background)) }
        }
        XCTAssertGreaterThan(contrast, 0.4, "The card title must actually render against its background")
    }

    /// D193② (the user chose "add a row"): a whole disk's Folders list ends
    /// with the space macOS frees by itself, inside the list and below every
    /// folder; the same scan of a home folder has no such row.
    func testTheTopOfADiskEndsWithItsPurgeableSpace() async throws {
        do {
            let records = Records()
            let window = window(result: try Self.purgeableDisk(), records: records)
            defer { close(window) }
            try await settle(window) { records.frames["careStudio.spaceLens.purgeable"] != nil }
            let row = try XCTUnwrap(records.frames["careStudio.spaceLens.purgeable"], "the purgeable row")
            let list = try XCTUnwrap(records.frames["careStudio.spaceLens.list"])
            XCTAssertTrue(list.insetBy(dx: -0.5, dy: -0.5).contains(row), "the row \(row) stays in the list \(list)")
            let folders = records.frames.filter { $0.key.hasPrefix("careStudio.spaceLens.row.") }
            XCTAssertEqual(folders.count, 3, "the disk's three folders are listed")
            for (id, folder) in folders {
                XCTAssertLessThanOrEqual(folder.maxY, row.minY + 0.5, "\(id) is above the purgeable row")
            }
        }
        let records = Records()
        let window = window(result: try Self.purgeableDisk(kind: .homeDirectory), records: records)
        defer { close(window) }
        try await settle(window) { records.frames["careStudio.spaceLens.list"] != nil }
        XCTAssertNil(records.frames["careStudio.spaceLens.purgeable"], "a home folder's scan has no purgeable row")
    }

    /// Three folders on a disk with 29.6 GB of purgeable space, the figure the
    /// 10-23 comparison read on this Mac.
    private static func purgeableDisk(kind: StorageMapScanTarget.Kind = .internalVolume) throws -> StorageMapAnalysisResult {
        let index = SpaceMapMemoryIndex.make(rootPath: "/Volumes/Fixture", children: [
            .directory("Users", [.file("Movies.mov", 300_000_000_000)]),
            .directory("Applications", [.file("Editor.app", 64_000_000_000)]),
            .directory("System", [.file("Kernel", 30_000_000_000)])])
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath, using: index)
        return StorageMapAnalysisResult(target: .init(path: index.rootPath, title: "Macintosh HD", kind: kind),
            volumeTotalBytes: 994_610_000_000, volumeAvailableBytes: 327_330_000_000, inspectedItemCount: 6,
            omittedItemCount: 0, scanSeconds: 1, index: index, rootSnapshot: snapshot,
            volumePurgeableBytes: 29_600_000_000)
    }

    func testCaptureBlocksReviewEvidence() async throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_SPACEMAP_EVIDENCE"] else {
            throw XCTSkip("PNGs require STORAGE_CLEANER_SPACEMAP_EVIDENCE")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for light in [false, true] {
                for size in [CGSize(width: 1_280, height: 763), CGSize(width: 1_024, height: 734), CGSize(width: 760, height: 600)] {
                    try await capture(directory: directory, scene: "blocks", size: size, language: language, light: light)
                }
            }
        }
        let zh = MiniWindowLogicLanguageScope(.zhHans)
        try await capture(directory: directory, scene: "full", language: .zhHans, prepare: { window, _ in
            try self.press(L10n.text("全宽显示", "Full Width"), in: window)
        })
        try await capture(directory: directory, scene: "selection", language: .zhHans, prepare: { window, _ in
            let map = try await self.ready(window)
            let files = map.tiles.filter { self.entry($0)?.isDirectory == false && self.entry($0)?.role == .content }
            let checked = try XCTUnwrap(files.first)
            let selected = try XCTUnwrap(files.dropFirst().first)
            map.send(.click(self.point(checked, bridge: map), count: 2))
            map.send(.click(self.point(selected, bridge: map), count: 1))
        })
        try await capture(directory: directory, scene: "bubbles", language: .zhHans, style: .bubbles)
        zh.restore()
        for (language, light) in [(AppLanguage.zhHans, false), (.english, true)] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            try await capture(directory: directory, scene: "hover", language: language, light: light, prepare: { window, _ in
                let map = try await self.ready(window)
                let tile = try XCTUnwrap(map.tiles.first { self.entry($0)?.path.contains("/原始拍摄/") == true })
                map.send(.pointer(self.point(tile, bridge: map)))
            })
            try await capture(result: richResult(), directory: directory, scene: "rich", language: language, light: light)
            // D193②: the Purgeable Space row at the end of a disk's Folders list.
            try await capture(result: try Self.purgeableDisk(), directory: directory, scene: "purgeable",
                              language: language, light: light)
            for (scene, title, lastLine) in [("rich-hover-reclaim", "node_modules", 4), ("rich-hover-blocked", "受保护目录", 3)] {
                try await capture(result: richResult(), directory: directory, scene: scene, language: language, light: light,
                    prepare: { window, records in
                        let map = try await self.ready(window)
                        let tile = try XCTUnwrap(map.tiles.first { self.entry($0)?.title == title })
                        map.send(.pointer(self.point(tile, bridge: map)))
                        let lineKey = "careStudio.spaceLens.hoverCard.line.\(lastLine)"
                        try await self.settle(window) { records.frames[lineKey] != nil }
                        let card = try XCTUnwrap(records.frames["careStudio.spaceLens.hoverCard"])
                        let blocks = try XCTUnwrap(records.frames["careStudio.spaceLens.blocks"])
                        let line = try XCTUnwrap(records.frames[lineKey])
                        XCTAssertTrue(blocks.insetBy(dx: -0.5, dy: -0.5).contains(card))
                        XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(line), "The complete reason must fit inside the card")
                        if scene == "rich-hover-blocked" {
                            XCTAssertGreaterThan(line.height, 22, "The protected reason wraps onto multiple lines")
                        }
                    })
            }
        }
    }

    private func capture(result: StorageMapAnalysisResult = FeatureLightfieldFileResultFixture.analysis,
                         directory: URL, scene: String, size: CGSize = CGSize(width: 1_024, height: 734),
                         language: AppLanguage, light: Bool = false, style: SpaceMapViewStyle = .blocks,
                         prepare: (@MainActor (NSWindow, Records) async throws -> Void)? = nil) async throws {
        let records = Records()
        let window = window(result: result, records: records, size: size, style: style, light: light)
        defer { close(window) }
        if style == .blocks { _ = try await ready(window) }
        try await prepare?(window, records)
        if style == .blocks { _ = try await ready(window) }
        try await settle(window)
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let name = "b-\(scene)-\(Int(size.width))-\(language == .english ? "en" : "zh")-\(light ? "light" : "dark").png"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }

    private func press(_ label: String, in window: NSWindow) throws {
        func value(_ object: NSObject, _ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func text(_ object: NSObject, _ name: String) -> String? {
            switch value(object, name) {
            case let text as String: text
            case let text as NSAttributedString: text.string
            default: nil
            }
        }
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if text(object, "accessibilityRole") == NSAccessibility.Role.button.rawValue,
               text(object, "accessibilityLabel") == label || text(object, "accessibilityTitle") == label { return object }
            for name in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"] {
                for case let child as NSObject in (value(object, name) as? [Any]) ?? [] {
                    if let match = find(child) { return match }
                }
            }
            if let view = object as? NSView {
                for subview in view.subviews {
                    if let match = find(subview) { return match }
                }
            }
            return nil
        }
        let target = try XCTUnwrap(find(try XCTUnwrap(window.contentView)), label)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(target.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = try XCTUnwrap(target.method(for: selector))
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(target, selector))
    }

    private func richResult() throws -> StorageMapAnalysisResult {
        let base = SpaceMapMemoryIndex.make(rootPath: "/Fixture/Home", children: [
            .directory("node_modules", [.file("library.js", 45_000_000_000)]), .file("package.json", 1_000_000),
            .directory("Library", [.directory("Caches", [.file("cache.db", 30_000_000_000)])]),
            .directory(".build", [.file("debug.o", 25_000_000_000)]), .file("Package.swift", 1_000_000),
            .directory("估算目录", [.file("partial.mov", 18_000_000_000)]),
            .directory("受保护目录", [.file("private.db", 15_000_000_000)]),
            .directory("小文件", (0..<132).map { .file("small-\($0).txt", 700_000_000) })
        ], blocked: ["/Fixture/Home/受保护目录"])
        var directories = base.directories
        directories["/Fixture/Home/估算目录"]?.isComplete = false
        let index = StorageMapAnalysisIndex(rootPath: base.rootPath, rootVolumeIdentifier: nil, directories: directories,
            childrenByDirectory: base.childrenByDirectory, blockedDirectoryPaths: base.blockedDirectoryPaths, duplicateFilePaths: [])
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath, using: index)
            .referenced(totalBytes: directories[index.rootPath]!.sizeBytes + 35_000_000_000, isEstimated: true)
        return StorageMapAnalysisResult(target: .init(path: index.rootPath, title: L10n.text("示例目录", "Sample Folder"), kind: .homeDirectory),
            volumeTotalBytes: 1_000_000_000_000, volumeAvailableBytes: 400_000_000_000, inspectedItemCount: 150,
            omittedItemCount: 0, scanSeconds: 1, index: index, rootSnapshot: snapshot)
    }
}
#endif
