#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SpaceLensSidebarWindowTests: XCTestCase {
    private typealias Bridge = SpaceMapTreemapInputBridge.InputView

    private final class Records: ObservableObject {
        @Published var reclaim: CleanupSelectionReclaimable?
        @Published var estimating = false
        var frames: [String: CGRect] = [:]
        var opened: [StorageTreemapEntry] = []
        var toggled: [StorageTreemapEntry] = []
        var selected: Set<String> = []
        var surface = 0
        var color: SpaceMapColorMode = .type
        var setSurface: ((Int) -> Void)?
        var setStyle: ((SpaceMapViewStyle) -> Void)?
    }

    private struct Host: View {
        let result: StorageMapAnalysisResult
        @ObservedObject var records: Records
        @State private var navigation: [StorageMapDirectorySnapshot]
        @State private var surface: Int
        @State private var style: SpaceMapViewStyle = .blocks
        @State private var color: SpaceMapColorMode = .type
        @State private var selected: Set<String>

        init(result: StorageMapAnalysisResult, records: Records, surface: Int, selected: Bool) {
            self.result = result
            self.records = records
            _navigation = State(initialValue: [result.rootSnapshot])
            _surface = State(initialValue: surface)
            _selected = State(initialValue: selected ? Set(result.rootSnapshot.entries.prefix(2).map(\.path)) : [])
        }

        var body: some View {
            MainContentHost(route: .largeFiles, showsIntegratedTitlebar: false) {
                CareStudioSpaceLensPage(result: result, navigation: navigation,
                    types: FileLightfieldPresentation.types(result), largest: FileLightfieldPresentation.largest(result.index),
                    fileCount: FileLightfieldPresentation.fileCount(result.index), surface: $surface, mapStyle: $style, mapColorMode: $color,
                    checkedPaths: selected, selectionState: { selected.contains($0.path) ? .selected : .available },
                    selectedBytes: result.rootSnapshot.entries.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.sizeBytes },
                    selectionReclaim: records.reclaim, isEstimatingReclaim: records.estimating,
                    status: L10n.text("演示索引 · 未执行移动", "Demo index · No move performed"),
                    canReview: !selected.isEmpty, onReview: {}, onToggle: { entry in
                        records.toggled.append(entry)
                        if selected.contains(entry.path) { selected.remove(entry.path) } else { selected.insert(entry.path) }
                    }, onOpen: { open($0, fromRoot: false) }, onBreadcrumb: { level in
                        if navigation.indices.contains(level) { navigation = Array(navigation.prefix(level + 1)) }
                    }, onOpenFromRoot: { entry in records.opened.append(entry); open(entry, fromRoot: true) })
            }
            .environment(\.featurePresentationIsFixture, true)
            .environment(\.featureDisablesLayoutAnimations, true)
            .environment(\.accessibilityEnabled, true)
            .layoutProbe("sidebar.test.viewport")
            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in Task { @MainActor in records.frames = frames } }
            .onAppear {
                records.surface = surface
                records.selected = selected
                records.setSurface = { surface = $0 }
                records.setStyle = { style = $0 }
            }
            .onChange(of: surface) { _, value in records.surface = value }
            .onChange(of: color) { _, value in records.color = value }
            .onChange(of: selected) { _, value in records.selected = value }
            .onDisappear { records.setSurface = nil; records.setStyle = nil }
        }

        private func open(_ entry: StorageTreemapEntry, fromRoot: Bool) {
            guard let base = fromRoot ? result.rootSnapshot.path : navigation.last?.path else { return }
            var paths = [entry.path]
            var parent = DiskScanner.storageMapParentPath(entry.path)
            while parent != base {
                guard parent.hasPrefix(base + "/") else { return }
                paths.append(parent)
                parent = DiskScanner.storageMapParentPath(parent)
            }
            let scanner = DiskScanner(excludedPaths: [])
            let snapshots = paths.reversed().compactMap { try? scanner.storageMapSnapshot(at: $0, using: result.index) }
            guard snapshots.count == paths.count else { return }
            navigation = (fromRoot ? [result.rootSnapshot] : navigation) + snapshots
        }
    }

    private func window(result: StorageMapAnalysisResult = FeatureLightfieldFileResultFixture.analysis,
                        records: Records, size: CGSize = CGSize(width: 1_024, height: 734),
                        surface: Int = 0, light: Bool = false, selected: Bool = false) -> NSWindow {
        let controller = NSHostingController(rootView: Host(result: result, records: records, surface: surface, selected: selected)
            .environment(\.colorScheme, light ? .light : .dark))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
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
        for step in 0..<160 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
            if step >= 4, predicate() { return }
        }
        XCTFail("Space Lens sidebar did not settle")
    }

    private func subview<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.subview(type, in: $0) }.first
    }

    private func ready(_ window: NSWindow) async throws -> Bridge {
        try await settle(window) {
            guard let map = self.subview(Bridge.self, in: window.contentView) else { return false }
            return !map.tiles.isEmpty && abs(map.layoutSize.width - map.bounds.width) < 1
                && abs(map.layoutSize.height - map.bounds.height) < 1
        }
        return try XCTUnwrap(subview(Bridge.self, in: window.contentView))
    }

    private func objectValue(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }

    private func text(_ object: NSObject, _ name: String) -> String? {
        let value = objectValue(object, name)
        return (value as? String) ?? (value as? NSAttributedString)?.string
    }

    private func elements(_ window: NSWindow) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            found.append(object)
            for key in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"] {
                for case let child as NSObject in (objectValue(object, key) as? [Any]) ?? [] { visit(child) }
            }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        if let view = window.contentView { visit(view) }
        return found
    }

    private func button(_ title: String, in window: NSWindow) throws -> NSObject {
        try XCTUnwrap(elements(window).first {
            text($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue
                && (text($0, "accessibilityLabel") == title || text($0, "accessibilityTitle") == title)
        }, title)
    }

    private func press(_ title: String, in window: NSWindow) throws {
        let target = try button(title, in: window)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = try XCTUnwrap(target.method(for: selector))
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(target, selector))
    }

    private func clickCheckbox(_ entry: StorageTreemapEntry, selected: Bool, window: NSWindow, records: Records) async throws {
        try await click(probe: "careStudio.spaceLens.check." + entry.id, entry: entry, window: window, records: records) {
            records.selected.contains(entry.path) == selected
        }
    }

    private func click(probe: String, entry: StorageTreemapEntry, window: NSWindow, records: Records,
                       until predicate: () -> Bool) async throws {
        var succeeded = false
        defer {
            if !succeeded {
                print("Space Lens click failed: \(probe)")
                diagnoseRow(entry, window: window, records: records)
            }
        }
        try await settle(window) { records.frames[probe] != nil }
        let frame = try XCTUnwrap(records.frames[probe], probe)
        let viewport = try XCTUnwrap(records.frames["sidebar.test.viewport"])
        let view = try XCTUnwrap(window.contentView)
        // Probes use top-down viewport coordinates; NSEvent needs window coordinates.
        let point = CGPoint(x: view.bounds.minX + frame.midX - viewport.minX,
            y: view.isFlipped ? view.bounds.minY + frame.midY - viewport.minY : view.bounds.maxY - (frame.midY - viewport.minY))
        let location = view.convert(point, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: timestamp + Double(offset) * 0.01, windowNumber: window.windowNumber, context: nil,
                eventNumber: offset, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        try await settle(window, until: predicate)
        succeeded = predicate()
    }

    private func diagnoseRow(_ entry: StorageTreemapEntry, window: NSWindow, records: Records) {
        print("Space Lens row: \(entry.id)")
        let row = records.frames["careStudio.spaceLens.row." + entry.id]?.insetBy(dx: -8, dy: -8)
        let viewport = records.frames["sidebar.test.viewport"]
        for object in elements(window) {
            let label = text(object, "accessibilityLabel") ?? text(object, "accessibilityTitle") ?? ""
            var nearby = label.contains(entry.title)
            if let row, let viewport, let view = window.contentView,
               object.responds(to: NSSelectorFromString("accessibilityFrame")),
               let screen = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue {
                let local = view.convert(window.convertFromScreen(screen), from: nil)
                let frame = CGRect(x: viewport.minX + local.minX,
                    y: viewport.minY + (view.isFlipped ? local.minY : view.bounds.height - local.maxY),
                    width: local.width, height: local.height)
                nearby = nearby || row.intersects(frame)
            }
            if nearby {
                print("  role=\(text(object, "accessibilityRole") ?? "unknown") label=\(label)")
            }
        }
    }

    private func axFrame(_ object: NSObject, window: NSWindow, viewport: CGRect) throws -> CGRect {
        XCTAssertTrue(object.responds(to: NSSelectorFromString("accessibilityFrame")))
        let screen = try XCTUnwrap((object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
        let view = try XCTUnwrap(window.contentView)
        let local = view.convert(window.convertFromScreen(screen), from: nil)
        return CGRect(x: viewport.minX + local.minX,
                      y: viewport.minY + (view.isFlipped ? local.minY : view.bounds.height - local.maxY),
                      width: local.width, height: local.height)
    }

    private func query(_ value: String, window: NSWindow) throws {
        let field = try XCTUnwrap(subview(NSTextField.self, in: window.contentView))
        XCTAssertTrue(field.isEditable)
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    private func key(_ characters: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code))
    }

    private func rows(_ records: Records) -> [String] { records.frames.keys.filter { $0.hasPrefix("careStudio.spaceLens.row.") } }

    private func assertSpacing(_ titles: [String], equals spacing: CGFloat, window: NSWindow, viewport: CGRect,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let frames = try titles.map { try axFrame(button($0, in: window), window: window, viewport: viewport) }
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(left.midY, right.midY, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(right.minX - left.maxX, spacing, accuracy: 0.5, file: file, line: line)
        }
    }

    func testTabsHeaderLegendAndWorthFitAtEverySupportedSizeInBothLanguages() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let records = Records()
            let window = window(result: try richResult(), records: records)
            defer { close(window) }
            for size in [CGSize(width: 1_280, height: 763), CGSize(width: 1_024, height: 734), CGSize(width: 760, height: 600),
                         CGSize(width: 604, height: 490), CGSize(width: 473, height: 360)] {
                records.setSurface?(0)
                window.setContentSize(size)
                try await settle(window) { abs((records.frames["sidebar.test.viewport"]?.width ?? 0) - size.width) < 0.5 }
                let list = try XCTUnwrap(records.frames["careStudio.spaceLens.list"])
                let action = try XCTUnwrap(records.frames["careStudio.action"])
                let viewport = try XCTUnwrap(records.frames["sidebar.test.viewport"])
                let titles = [L10n.text("目录", "Folders"), L10n.text("文件类型", "File Types"),
                              L10n.text("最大的文件", "Largest Files"), L10n.text("值得一看", "Worth a Look")]
                var tabs: [CGRect] = []
                for title in titles {
                    let frame = try axFrame(button(title, in: window), window: window, viewport: viewport)
                    XCTAssertTrue(list.insetBy(dx: -0.5, dy: -0.5).contains(frame), title)
                    let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
                    XCTAssertGreaterThanOrEqual(frame.width, width - 1, "Untruncated \(title)")
                    for other in tabs {
                        XCTAssertFalse(frame.insetBy(dx: 0.5, dy: 0.5).intersects(other))
                        if abs(frame.midY - other.midY) < 1 { XCTAssertGreaterThanOrEqual(frame.minX - other.maxX, 13.5) }
                    }
                    tabs.append(frame)
                }
                if language == .zhHans && size.width >= 1_024 {
                    try assertSpacing(titles, equals: 26, window: window, viewport: viewport)
                    try assertSpacing(["气泡", "方块"], equals: 26, window: window, viewport: viewport)
                    try assertSpacing(["类型", "用途"], equals: 26, window: window, viewport: viewport)
                }
                XCTAssertLessThanOrEqual(list.maxY, action.minY + 0.5)
                if size.width >= 680 {
                    let filter = try XCTUnwrap(records.frames["careStudio.spaceLens.filter"])
                    let path = try XCTUnwrap(records.frames["careStudio.spaceLens.path"])
                    let more = try XCTUnwrap(records.frames["careStudio.spaceLens.more"])
                    let legend = try XCTUnwrap(records.frames["careStudio.spaceLens.legend"])
                    let blocks = try XCTUnwrap(records.frames["careStudio.spaceLens.blocks"])
                    XCTAssertLessThanOrEqual(path.maxX, filter.minX)
                    XCTAssertLessThanOrEqual(filter.maxX, more.minX)
                    XCTAssertGreaterThanOrEqual(legend.minX, blocks.minX - 0.5)
                    XCTAssertLessThanOrEqual(legend.maxX, blocks.maxX + 0.5)
                    XCTAssertGreaterThanOrEqual(legend.minY, blocks.maxY - 0.5)
                    XCTAssertLessThanOrEqual(legend.maxY, action.minY + 0.5)
                    XCTAssertFalse(legend.intersects(list))
                } else {
                    XCTAssertNil(records.frames["careStudio.spaceLens.filter"])
                    XCTAssertNil(records.frames["careStudio.spaceLens.legend"])
                }
                records.setSurface?(3)
                try await settle(window) { records.frames["careStudio.spaceLens.worth"] != nil && !self.rows(records).isEmpty }
                let worth = try XCTUnwrap(records.frames["careStudio.spaceLens.worth"])
                XCTAssertLessThanOrEqual(worth.maxY, action.minY + 0.5)
            }
        }
    }

    func testEveryLegendItemFitsWithinThreeRowsAboveTheActionInBothLanguages() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let records = Records()
            let window = window(records: records)
            defer { close(window) }
            for size in [CGSize(width: 760, height: 600), CGSize(width: 1_024, height: 734), CGSize(width: 1_280, height: 763)] {
                window.setContentSize(size)
                _ = try await ready(window)
                for mode in [SpaceMapColorMode.type, .purpose] {
                    try press(mode == .type ? L10n.text("类型", "Type") : L10n.text("用途", "Purpose"), in: window)
                    let items = SpaceMapTreemapPainter.legendItems(mode: mode)
                    let ids = Set(items.map { "careStudio.spaceLens.legend.\($0.id)" })
                    try await settle(window) {
                        records.color == mode && abs((records.frames["sidebar.test.viewport"]?.width ?? 0) - size.width) < 0.5
                            && Set(records.frames.keys.filter { $0.hasPrefix("careStudio.spaceLens.legend.") }) == ids
                    }
                    let legend = try XCTUnwrap(records.frames["careStudio.spaceLens.legend"])
                    let blocks = try XCTUnwrap(records.frames["careStudio.spaceLens.blocks"])
                    let action = try XCTUnwrap(records.frames["careStudio.action"])
                    let frames = try ids.map { try XCTUnwrap(records.frames[$0], $0) }
                    for frame in frames {
                        XCTAssertGreaterThan(frame.width, 0)
                        XCTAssertGreaterThan(frame.height, 0)
                        XCTAssertTrue(legend.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(size) \(language) \(mode): \(frame)")
                    }
                    XCTAssertLessThanOrEqual(Set(frames.map { Int(($0.midY * 2).rounded()) }).count, 3)
                    XCTAssertGreaterThanOrEqual(legend.minX, blocks.minX - 0.5)
                    XCTAssertLessThanOrEqual(legend.maxX, blocks.maxX + 0.5)
                    XCTAssertGreaterThanOrEqual(legend.minY, blocks.maxY - 0.5)
                    XCTAssertLessThanOrEqual(legend.maxY, action.minY + 0.5)
                }
            }
        }
    }

    func testColorModeRoundTripsPreserveEveryTileAndLegendFrameAtAllWideSizesInBothLanguages() async throws {
        let result = try richResult()
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for size in [CGSize(width: 760, height: 600), CGSize(width: 1_024, height: 734), CGSize(width: 1_280, height: 763)] {
                let records = Records()
                let window = window(result: result, records: records, size: size)
                defer { close(window) }
                let map = try await ready(window)
                let tiles = map.tiles
                let blocks = try XCTUnwrap(records.frames["careStudio.spaceLens.blocks"])
                let legend = try XCTUnwrap(records.frames["careStudio.spaceLens.legend"])
                for _ in 0..<2 {
                    for mode in [SpaceMapColorMode.purpose, .type] {
                        try press(mode == .type ? L10n.text("类型", "Type") : L10n.text("用途", "Purpose"), in: window)
                        let ids = Set(SpaceMapTreemapPainter.legendItems(mode: mode).map { "careStudio.spaceLens.legend.\($0.id)" })
                        try await settle(window) {
                            records.color == mode
                                && Set(records.frames.keys.filter { $0.hasPrefix("careStudio.spaceLens.legend.") }) == ids
                        }
                        let current = try await ready(window)
                        XCTAssertEqual(current.tiles, tiles, "\(size) \(language) \(mode)")
                        XCTAssertEqual(records.frames["careStudio.spaceLens.blocks"], blocks)
                        XCTAssertEqual(records.frames["careStudio.spaceLens.legend"], legend)
                        let action = try XCTUnwrap(records.frames["careStudio.action"])
                        XCTAssertLessThanOrEqual(legend.maxY, action.minY + 0.5)
                        for id in ids {
                            let frame = try XCTUnwrap(records.frames[id], id)
                            XCTAssertGreaterThan(frame.width, 0)
                            XCTAssertGreaterThan(frame.height, 0)
                            XCTAssertTrue(legend.insetBy(dx: -0.5, dy: -0.5).contains(frame), id)
                            XCTAssertLessThanOrEqual(frame.maxY, action.minY + 0.5, id)
                        }
                    }
                }
            }
        }
    }

    func testSelectingAndClearingPreservesListBlocksAndBubblePositionsInBothLanguages() async throws {
        let result = FeatureLightfieldFileResultFixture.analysis
        let entry = try XCTUnwrap(StorageTreemapPresentation.visibleEntries(from: result.rootSnapshot).first)
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let records = Records()
            let window = window(records: records)
            defer { close(window) }
            for style in [SpaceMapViewStyle.blocks, .bubbles] {
                records.setStyle?(style)
                let mapID = "careStudio.spaceLens." + (style == .blocks ? "blocks" : "bubbles")
                try await settle(window) { records.frames[mapID] != nil && records.selected.isEmpty }
                let list = try XCTUnwrap(records.frames["careStudio.spaceLens.list"])
                let map = try XCTUnwrap(records.frames[mapID])
                let reclaim = try XCTUnwrap(records.frames["careStudio.spaceLens.reclaim"])
                let hint = L10n.text("勾选项目后，这里显示清空废纸篓后约可释放的空间",
                                     "Select items to see the estimated space freed after emptying the Trash")
                XCTAssertTrue(elements(window).contains { (text($0, "accessibilityValue") ?? text($0, "accessibilityLabel")) == hint })
                for selected in [true, false] {
                    try await clickCheckbox(entry, selected: selected, window: window, records: records)
                    XCTAssertEqual(try XCTUnwrap(records.frames["careStudio.spaceLens.list"]).minY, list.minY, accuracy: 0.5)
                    XCTAssertEqual(try XCTUnwrap(records.frames[mapID]).minY, map.minY, accuracy: 0.5)
                    XCTAssertEqual(try XCTUnwrap(records.frames["careStudio.spaceLens.reclaim"]).height, reclaim.height, accuracy: 0.5)
                }
            }
        }
    }

    func testMatchCountFollowsColorInOneRowAndStyleInTwoRowsWithoutDisplacingControls() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for size in [CGSize(width: 1_280, height: 763), CGSize(width: 760, height: 600)] {
                let records = Records()
                let window = window(records: records, size: size)
                defer { close(window) }
                _ = try await ready(window)
                try query("mov", window: window)
                try await settle(window) { records.frames["careStudio.spaceLens.matches"] != nil }
                let viewport = try XCTUnwrap(records.frames["sidebar.test.viewport"])
                let style = try axFrame(button(L10n.text("方块", "Blocks"), in: window), window: window, viewport: viewport)
                let color = try XCTUnwrap(records.frames["careStudio.spaceLens.colorMode"])
                let count = try XCTUnwrap(records.frames["careStudio.spaceLens.matches"])
                let depth = try XCTUnwrap(records.frames["careStudio.spaceLens.depth"])
                let panel = try XCTUnwrap(records.frames["careStudio.spaceLens.mapStyle"])
                let singleRow = abs(style.midY - color.midY) < 1
                if size.width == 1_280 { XCTAssertTrue(singleRow) }
                if size.width == 760 && language == .english { XCTAssertFalse(singleRow) }
                XCTAssertEqual(count.midY, singleRow ? color.midY : style.midY, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(count.minX, (singleRow ? color.maxX : style.maxX) - 0.5)
                if singleRow { XCTAssertLessThanOrEqual(count.maxX, depth.minX + 0.5) }
                let separators = records.frames.filter { $0.key.hasPrefix("careStudio.spaceLens.controlSeparator.") }
                XCTAssertEqual(separators.count, singleRow ? 2 : 0)
                if singleRow {
                    let styleSeparator = try XCTUnwrap(separators["careStudio.spaceLens.controlSeparator.style"])
                    let depthSeparator = try XCTUnwrap(separators["careStudio.spaceLens.controlSeparator.depth"])
                    for separator in [styleSeparator, depthSeparator] {
                        XCTAssertEqual(separator.width, 21, accuracy: 0.5) // 1 pt line + 10 pt on each side.
                        XCTAssertEqual(separator.height, 16, accuracy: 0.5)
                    }
                    XCTAssertEqual(styleSeparator.minX, style.maxX, accuracy: 0.5)
                    XCTAssertEqual(styleSeparator.maxX, color.minX, accuracy: 0.5)
                    XCTAssertEqual(depthSeparator.minX, count.maxX, accuracy: 0.5)
                    XCTAssertEqual(depthSeparator.maxX, depth.minX, accuracy: 0.5)
                }
                XCTAssertTrue(elements(window).contains { text($0, "accessibilityLabel") == L10n.text("着色方式", "Color by") })
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(color))
                XCTAssertTrue(panel.insetBy(dx: -0.5, dy: -0.5).contains(depth))
            }
        }
    }

    func testFilterChangesBlocksAndRowsAndEscapeRestoresThem() async throws {
        let records = Records()
        let window = window(records: records)
        defer { close(window) }
        let initial = try await ready(window).tiles.count
        let initialRows = rows(records).count
        try query("mov", window: window)
        try await settle(window) { (self.subview(Bridge.self, in: window.contentView)?.tiles.count ?? initial) < initial && self.rows(records).count < initialRows }
        let map = try XCTUnwrap(subview(Bridge.self, in: window.contentView))
        let expected = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: FeatureLightfieldFileResultFixture.analysis.index,
            basePath: FeatureLightfieldFileResultFixture.analysis.index.rootPath, keyword: "mov"))
        XCTAssertFalse(map.tiles.isEmpty)
        for tile in map.tiles {
            if case let .entry(entry) = tile.kind { XCTAssertNotNil(expected.keep(forPath: entry.path), entry.path) }
        }
        window.sendEvent(try key("\u{1B}", code: 53, window: window))
        try await settle(window) { self.subview(Bridge.self, in: window.contentView)?.tiles.count == initial && self.rows(records).count == initialRows }
        XCTAssertEqual(subview(NSTextField.self, in: window.contentView)?.stringValue, "")
    }

    func testSlashFocusesFilterAndHiddenModesHaveNoSearchField() async throws {
        let records = Records()
        let window = window(records: records)
        defer { close(window) }
        let map = try await ready(window)
        window.makeFirstResponder(map)
        map.keyDown(with: try key("/", code: 44, window: window))
        try await settle(window) { self.subview(NSTextField.self, in: window.contentView)?.currentEditor() === window.firstResponder }
        XCTAssertTrue(window.firstResponder is NSTextView)
        let moreX = try XCTUnwrap(records.frames["careStudio.spaceLens.more"]?.maxX)
        records.setStyle?(.bubbles)
        try await settle(window) { records.frames["careStudio.spaceLens.filter"] == nil }
        XCTAssertEqual(try XCTUnwrap(records.frames["careStudio.spaceLens.more"]?.maxX), moreX, accuracy: 0.5)
        records.setStyle?(.blocks)
        _ = try await ready(window)
        records.setSurface?(2)
        try await settle(window) { records.frames["careStudio.spaceLens.filter"] == nil }
    }

    func testFilterSurvivesNavigationAndClearsAfterSurfaceOrWidthChanges() async throws {
        let records = Records()
        let window = window(records: records)
        defer { close(window) }
        let initial = try await ready(window).tiles.count
        try query("mov", window: window)
        try await settle(window) { (self.subview(Bridge.self, in: window.contentView)?.tiles.count ?? initial) < initial }
        let map = try XCTUnwrap(subview(Bridge.self, in: window.contentView))
        let folder = try XCTUnwrap(map.tiles.first { tile in
            if case let .entry(entry) = tile.kind { return tile.depth == 0 && entry.canDescend }
            return false
        })
        let rect = map.viewport.project(folder.header ?? folder.frame)
        map.send(.click(CGPoint(x: rect.midX, y: rect.midY), count: 2))
        try await settle(window) { self.subview(Bridge.self, in: window.contentView)?.path != FeatureLightfieldFileResultFixture.analysis.index.rootPath }
        XCTAssertEqual(subview(NSTextField.self, in: window.contentView)?.stringValue, "mov")
        let nested = try await ready(window)
        nested.send(.key(.back))
        try await settle(window) { self.subview(Bridge.self, in: window.contentView)?.path == FeatureLightfieldFileResultFixture.analysis.index.rootPath }
        XCTAssertEqual(subview(NSTextField.self, in: window.contentView)?.stringValue, "mov")
        records.setSurface?(2)
        try await settle(window)
        records.setSurface?(0)
        _ = try await ready(window)
        XCTAssertEqual(subview(NSTextField.self, in: window.contentView)?.stringValue, "")
        try query("mov", window: window)
        window.setContentSize(CGSize(width: 604, height: 490))
        try await settle(window) { records.frames["careStudio.spaceLens.filter"] == nil }
        window.setContentSize(CGSize(width: 1_024, height: 734))
        _ = try await ready(window)
        XCTAssertEqual(subview(NSTextField.self, in: window.contentView)?.stringValue, "")
    }

    func testPurposeChangesColorWithoutChangingLayoutAndSurvivesSurfaceChanges() async throws {
        let result = try richResult()
        let records = Records()
        let window = window(result: result, records: records)
        defer { close(window) }
        let map = try await ready(window)
        let tiles = map.tiles
        try press(L10n.text("用途", "Purpose"), in: window)
        try await settle(window) { records.color == .purpose }
        XCTAssertEqual(map.tiles, tiles)
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: result.index, homePath: result.index.rootPath))
        XCTAssertTrue(tiles.contains { tile in
            SpaceMapTreemapPainter.decoration(for: tile, dark: true, purposes: purposes).fill
                != SpaceMapTreemapPainter.decoration(for: tile, dark: true, purposes: purposes, colorMode: records.color).fill
        })
        records.setSurface?(2)
        try await settle(window)
        records.setSurface?(0)
        _ = try await ready(window)
        XCTAssertEqual(records.color, .purpose)
        XCTAssertNotNil(records.frames["careStudio.spaceLens.legend"])
    }

    func testWorthToggleAndOpenUseTheExistingCallbacksAndReturnToFolders() async throws {
        let result = try richResult()
        let records = Records()
        let window = window(result: result, records: records, surface: 3)
        defer { close(window) }
        try await settle(window) { !self.rows(records).isEmpty }
        XCTAssertNotNil(records.frames["careStudio.spaceLens.worth"])
        let path = result.index.rootPath + "/Library/Caches"
        let parent = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: result.index.rootPath + "/Library", using: result.index)
        let entry = try XCTUnwrap(parent.entries.first { $0.path == path })
        try await clickCheckbox(entry, selected: true, window: window, records: records)
        XCTAssertEqual(records.toggled.last?.path, path)
        try await click(probe: "careStudio.spaceLens.open." + entry.id, entry: entry, window: window, records: records) {
            records.surface == 0 && !records.opened.isEmpty
        }
        XCTAssertEqual(records.opened.last?.path, path)
        let map = try await ready(window)
        XCTAssertEqual(map.path, path)
    }

    func testReclaimShowsInjectedBytesAndPendingEllipsisInBothLanguages() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let records = Records()
            records.reclaim = CleanupSelectionReclaimable(items: [(12_345_678, nil)])
            let window = window(records: records, selected: true)
            defer { close(window) }
            try await settle(window) { records.frames["careStudio.spaceLens.reclaim"] != nil }
            XCTAssertTrue(elements(window).contains { (text($0, "accessibilityValue") ?? text($0, "accessibilityLabel") ?? "").contains(ByteFormat.storageString(12_345_678)) })
            records.estimating = true
            try await settle(window)
            XCTAssertTrue(elements(window).contains { (text($0, "accessibilityValue") ?? text($0, "accessibilityLabel") ?? "").contains("…") })
        }
    }

    func testCaptureSidebarEvidenceWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_SPACEMAP_EVIDENCE"], !path.isEmpty else {
            throw XCTSkip("Set STORAGE_CLEANER_SPACEMAP_EVIDENCE to export sidebar screenshots")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (language, light) in [(AppLanguage.zhHans, false), (.english, true)] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            try await capture(directory, scene: "worth", result: richResult(), language: language, light: light, surface: 3)
            try await capture(directory, scene: "filter", language: language, light: light) { window, _ in try self.query("mov", window: window) }
            try await capture(directory, scene: "purpose", result: richResult(), language: language, light: light) { window, _ in
                try self.press(L10n.text("用途", "Purpose"), in: window)
            }
            let rich = try richResult()
            try await capture(directory, scene: "purpose-hover", result: rich, language: language, light: light) { window, records in
                try self.press(L10n.text("用途", "Purpose"), in: window)
                let map = try await self.ready(window)
                let tile = try XCTUnwrap(map.tiles.first {
                    guard case let .entry(entry) = $0.kind else { return false }
                    return entry.isDirectory && entry.path.hasPrefix(rich.index.rootPath + "/.codex/worktrees/")
                })
                let rect = map.viewport.project(tile.header ?? tile.frame)
                map.send(.pointer(CGPoint(x: rect.midX, y: rect.midY)))
                try await self.settle(window) {
                    records.color == .purpose && records.frames["careStudio.spaceLens.hoverCard.line.2"] != nil
                }
                let card = try XCTUnwrap(records.frames["careStudio.spaceLens.hoverCard"])
                let blocks = try XCTUnwrap(records.frames["careStudio.spaceLens.blocks"])
                let purpose = try XCTUnwrap(records.frames["careStudio.spaceLens.hoverCard.line.2"])
                XCTAssertTrue(blocks.insetBy(dx: -0.5, dy: -0.5).contains(card))
                XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(purpose))
            }
            try await capture(directory, scene: "reclaim", language: language, light: light, selected: true) { _, records in
                let selectedBytes = FeatureLightfieldFileResultFixture.analysis.rootSnapshot.entries.prefix(2).reduce(Int64(0)) { $0 + $1.sizeBytes }
                records.reclaim = CleanupSelectionReclaimable(items: [(selectedBytes, .init(cloneSharedBytes: 7_000_000_000,
                    snapshotHeldBytes: 0, unknownBytes: 0, wholeCloneGroupBytes: 3_000_000_000))])
            }
            for size in [CGSize(width: 760, height: 600), CGSize(width: 1_280, height: 763)] {
                try await capture(directory, scene: "tabs", language: language, light: light, size: size)
            }
            if language == .zhHans { try await capture(directory, scene: "type-legend", language: language, light: light) }
        }
    }

    private func capture(_ directory: URL, scene: String, result: StorageMapAnalysisResult = FeatureLightfieldFileResultFixture.analysis,
                         language: AppLanguage, light: Bool, size: CGSize = CGSize(width: 1_024, height: 734), surface: Int = 0,
                         selected: Bool = false, prepare: (@MainActor (NSWindow, Records) async throws -> Void)? = nil) async throws {
        let records = Records()
        let window = window(result: result, records: records, size: size, surface: surface, light: light, selected: selected)
        defer { close(window) }
        if surface == 0 { _ = try await ready(window) }
        else { try await settle(window) { !self.rows(records).isEmpty } }
        try await prepare?(window, records)
        try await Task.sleep(for: .milliseconds(250))
        try await settle(window)
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let name = "c-\(scene)-\(Int(size.width))-\(language == .english ? "en" : "zh")-\(light ? "light" : "dark").png"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }

    private func richResult() throws -> StorageMapAnalysisResult {
        let index = SpaceMapMemoryIndex.make(rootPath: "/Fixture/Home", children: [
            .directory("node_modules", [.file("library.js", 45_000_000_000)]), .file("package.json", 1_000),
            .directory("Library", [.directory("Caches", [.file("cache.db", 30_000_000_000)])]),
            .directory(".build", [.file("debug.o", 25_000_000_000)]), .file("Package.swift", 1_000),
            .directory(".codex", [.directory("worktrees", (0..<3).map { .directory("experiment-\($0)", [.file("index.db", 4_000_000_000)]) })]),
            .directory("Movies", [.file("footage.mov", 8_000_000_000)]), .directory("Documents", [.file("notes.pdf", 5_000_000_000)])
        ])
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath, using: index)
        return .init(target: .init(path: index.rootPath, title: "~", kind: .homeDirectory), volumeTotalBytes: 1_000_000_000_000,
            volumeAvailableBytes: 400_000_000_000, inspectedItemCount: 20, omittedItemCount: 0, scanSeconds: 1, index: index, rootSnapshot: snapshot)
    }
}
#endif
