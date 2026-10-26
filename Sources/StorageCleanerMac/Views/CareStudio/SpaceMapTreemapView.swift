import AppKit
import SwiftUI

@MainActor
struct SpaceMapTreemapView: View {
    typealias State = SpaceMapTreemapViewState
    typealias Tile = SpaceMapTreemapLayout.Tile
    let result: StorageMapAnalysisResult
    let snapshot: StorageMapDirectorySnapshot
    let navigation: [StorageMapDirectorySnapshot]
    let dataVersion: UInt64
    @ObservedObject var source: SpaceMapTreemapSource
    @Binding var levels: Int
    let isBusy: Bool
    let browseFailed: Bool
    let highlightedID: String?
    let checkedPaths: Set<String>
    let selectionState: (StorageTreemapEntry) -> FileAnalysisTrashSelectionState
    let onHighlight: (String?) -> Void
    let onOpen: (StorageTreemapEntry) -> Void
    let onToggle: (StorageTreemapEntry) -> Void
    let onBreadcrumb: (Int) -> Void
    let onForward: (() -> Void)?
    let onQuickLook: (String) -> Void
    let onReveal: (String) -> Void
    var filter: SpaceMapTreemapFilter.Result? = nil
    var filterKeyword = ""
    var colorMode: SpaceMapColorMode = .type
    var onFocusFilter: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @SwiftUI.State private var state = State()
    @SwiftUI.State private var displayed: Frame?
    @SwiftUI.State private var pointer: CGPoint?
    @SwiftUI.State private var hovered: Tile?
    @SwiftUI.State private var pending: Pending?
    @SwiftUI.State private var transition: State.Transition?
    @SwiftUI.State private var checkedIDs: Set<String> = []
    @SwiftUI.State private var labelCache = SpaceMapTreemapLabelCache()

    private struct Frame {
        let key: SpaceMapTreemapSource.Key
        let tiles: [Tile]
        let roots: [StorageTreemapEntry]
    }

    private struct Pending {
        enum Move { case enter(CGRect), back(leftPath: String, source: CGRect) }
        let originPath: String
        let targetPath: String
        let move: Move
    }

    private var animates: Bool { !reduceMotion && !disablesAnimations }
    private var tiles: [Tile] { displayed?.tiles ?? [] }
    private var ready: Bool {
        displayed?.key.path == snapshot.path && displayed?.key.version == dataVersion
            && displayed?.key.keyword == (filter?.keyword ?? filterKeyword)
    }
    private var now: TimeInterval { Date.timeIntervalSinceReferenceDate }

    var body: some View {
        GeometryReader { proxy in
            let key = SpaceMapTreemapSource.Key(path: snapshot.path, size: proxy.size, levels: levels, version: dataVersion,
                                                keyword: filter?.keyword ?? filterKeyword)
            let checked = checkedIDs
            let hover = SpaceMapTreemapPainter.hoverPresentation(for: transition == nil && ready ? hovered : nil,
                highlightedID: highlightedID, snapshot: snapshot, index: result.index,
                purposes: source.classification(for: dataVersion), colorMode: colorMode, selectionState: selectionState)
            ZStack(alignment: .topLeading) {
                if let transition {
                    TimelineView(.animation) { timeline in
                        drawing(at: timeline.date.timeIntervalSinceReferenceDate, checked: checked, hovered: hover.ids)
                    }
                    .task(id: transition.started) {
                        try? await Task.sleep(for: .seconds(transition.duration))
                        guard !Task.isCancelled else { return }
                        self.transition = nil
                    }
                } else {
                    drawing(at: 0, checked: checked, hovered: hover.ids)
                }
                SpaceMapTreemapInputBridge(tiles: tiles, viewport: state.viewport, path: displayed?.key.path ?? "",
                    layoutSize: displayed?.key.size ?? .zero,
                    highlightedID: highlightedID,
                    onInput: { handle($0, size: key.size) }, menu: menu,
                    onMenuAction: performMenu)
                if let filter, filter.matchedItems == 0 {
                    Text(SpaceLensWorthALook.emptyFilterTitle(filter.keyword))
                        .font(.system(size: 13)).foregroundStyle(CareStudioInk.secondary)
                        .multilineTextAlignment(.center).padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
                if let card = hover.card, let hovered, let pointer {
                    SpaceMapTreemapHoverCard(card: card, pointer: pointer, canvas: proxy.size,
                        tileOrigin: state.viewport.project(hovered.frame).origin)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("方块图", "Blocks map"))
            .accessibilityValue(SpaceMapTreemapPainter.accessibilitySummary(title: snapshot.title, entries: snapshot.entries))
            .accessibilityHint(L10n.text("左侧列表可逐项浏览和勾选", "Use the list on the left to browse and select individual items"))
            .task(id: filterKeyword.isEmpty || filter != nil ? key : nil) {
                guard key.keyword.isEmpty || filter != nil else { return }
                let input = SpaceMapTreemapSource.Input(snapshot: snapshot, index: result.index, filter: filter)
                guard let tiles = await source.layout(input, key: key), !Task.isCancelled else { return }
                install(tiles, roots: snapshot.entries, key: key)
            }
        }
        .onChange(of: snapshot.path) { old, new in
            forgetHover()
            if let pending, new != pending.targetPath && new != pending.originPath {
                self.pending = nil
            }
            if old != new { transition = nil }
        }
        .onChange(of: isBusy) { _, busy in
            // A failed asynchronous browse leaves the old path in place.
            if !busy, pending?.originPath == snapshot.path { pending = nil }
        }
        .onChange(of: browseFailed) { _, failed in if failed { pending = nil } }
        .onChange(of: checkedPaths) { _, paths in
            checkedIDs = SpaceMapTreemapPainter.checkedIDs(tiles: tiles, paths: paths)
        }
        .onChange(of: reduceMotion) { _, value in if value { transition = nil } }
        .onChange(of: disablesAnimations) { _, value in if value { transition = nil } }
        .onDisappear { pending = nil; transition = nil; forgetHover() }
    }

    private func drawing(at time: TimeInterval, checked: Set<String>, hovered: Set<String>) -> some View {
        let purposes = source.classification(for: dataVersion)
        return SpaceMapTreemapDrawing(tiles: tiles, layoutKey: displayed?.key,
            viewport: state.viewport, transition: transition, time: time,
            purposes: purposes, classificationVersion: purposes == nil ? nil : dataVersion,
            colorMode: colorMode,
            checkedIDs: checked, hoveredIDs: hovered, selectedID: state.selectedID,
            dark: colorScheme == .dark, displayScale: displayScale, labelCache: labelCache)
            .equatable()
    }

    private func install(_ tiles: [Tile], roots: [StorageTreemapEntry], key: SpaceMapTreemapSource.Key) {
        let old = displayed
        let canvas = CGRect(origin: .zero, size: key.size)
        if old?.key.path != key.path {
            var nextTransition: State.Transition?
            var leftPath: String?
            if let pending, pending.targetPath == key.path {
                switch pending.move {
                case let .enter(from):
                    nextTransition = .init(source: from, destination: canvas, started: now, reduceMotion: !animates)
                case let .back(path, from):
                    leftPath = path
                    if let tile = tiles.first(where: { entryPath($0) == path }) {
                        nextTransition = .init(source: from, destination: State.body(tile), started: now, reduceMotion: !animates)
                    }
                }
            } else if let old, old.key.path.hasPrefix(key.path == "/" ? "/" : key.path + "/") {
                leftPath = old.key.path
                if let tile = tiles.first(where: { entryPath($0) == old.key.path }) {
                    nextTransition = .init(source: CGRect(origin: .zero, size: old.key.size),
                                           destination: State.body(tile), started: now, reduceMotion: !animates)
                }
            } else if let tile = old?.tiles.first(where: { entryPath($0) == key.path }) {
                nextTransition = .init(source: state.viewport.project(State.body(tile)), destination: canvas,
                                       started: now, reduceMotion: !animates)
            }
            state.viewport = State.Viewport()
            state.selectedID = leftPath.flatMap { path in tiles.first(where: { entryPath($0) == path }).map(State.id) }
            transition = nextTransition?.duration == 0 ? nil : nextTransition
            pending = nil
            forgetHover()
        } else if old?.key != key {
            state.viewport = state.viewport.clamped(to: key.size)
            if !tiles.contains(where: { State.id($0) == state.selectedID }) { state.selectedID = nil }
            transition = nil
            forgetHover()
        }
        displayed = Frame(key: key, tiles: tiles, roots: roots)
        checkedIDs = SpaceMapTreemapPainter.checkedIDs(tiles: tiles, paths: checkedPaths)
    }

    private func hit(_ point: CGPoint) -> Tile? {
        guard ready, transition == nil else { return nil }
        return SpaceMapTreemapLayout.hitTest(tiles, at: state.viewport.unproject(point))
    }

    private func handle(_ input: SpaceMapTreemapInputBridge.Input, size: CGSize) {
        switch input {
        case let .pointer(point):
            pointer = point
            hovered = point.flatMap(hit)
            onHighlight(State.highlightedID(for: hovered, roots: displayed?.roots ?? []))
        case let .click(point, count):
            state.selectedID = hit(point).map(State.id)
            if count >= 2, let tile = hit(point) { activate(tile, size: size) }
        case let .zoom(factor, point, phase, momentum, time):
            guard ready, transition == nil else { return }
            pointer = point
            let action = state.zoom(factor: factor, at: point, tiles: tiles, size: size, phase: phase,
                                    momentum: momentum, time: time, canNavigate: !isBusy)
            perform(action, size: size)
            if pending == nil {
                hovered = hit(point)
                onHighlight(State.highlightedID(for: hovered, roots: displayed?.roots ?? []))
            }
        case let .pan(delta):
            state.pan(by: delta, size: size)
            if let pointer { hovered = hit(pointer) }
            onHighlight(State.highlightedID(for: hovered, roots: displayed?.roots ?? []))
        case let .key(key):
            switch key {
            case .activate:
                if let tile = tiles.first(where: { State.id($0) == state.selectedID }) { activate(tile, size: size) }
            case .toggle:
                if ready, !isBusy, let tile = tiles.first(where: { State.id($0) == state.selectedID }),
                   case let .entry(entry) = tile.kind, entry.role == .content { onToggle(entry) }
            case .escape: perform(state.escape(canNavigate: !isBusy), size: size)
            case .back: if !isBusy { goBack(size: size) }
            case .forward: if !isBusy { pending = nil; onForward?() }
            case .focusFilter: onFocusFilter()
            case let .depth(step): levels = min(6, max(1, levels + step))
            case let .direction(direction): state.move(direction, tiles: tiles)
            }
        }
    }

    private func activate(_ tile: Tile, size: CGSize) {
        guard ready, !isBusy else { return }
        switch tile.kind {
        case let .entry(entry):
            guard entry.role == .content else { return }
            if entry.canDescend { perform(.enter(entry, from: state.viewport.project(State.body(tile))), size: size) }
            else { onToggle(entry) }
        case let .others(parent, _, _):
            guard parent != snapshot.path,
                  let tile = tiles.first(where: { entryPath($0) == parent }), case let .entry(entry) = tile.kind else { return }
            perform(.enter(entry, from: state.viewport.project(State.body(tile))), size: size)
        }
    }

    private func perform(_ action: State.Action, size: CGSize) {
        switch action {
        case .none: break
        case let .reset(from):
            if animates {
                let canvas = CGRect(origin: .zero, size: size)
                transition = .init(source: from.project(canvas), destination: canvas, started: now)
            }
            forgetHover()
        case .back: if !isBusy { goBack(size: size) }
        case let .enter(entry, from):
            guard !isBusy else { return }
            pending = Pending(originPath: snapshot.path, targetPath: entry.path, move: .enter(from))
            forgetHover()
            onOpen(entry)
        }
    }

    private func goBack(size: CGSize) {
        guard navigation.count >= 2 else { return }
        pending = Pending(originPath: snapshot.path, targetPath: navigation[navigation.count - 2].path,
                          move: .back(leftPath: snapshot.path, source: CGRect(origin: .zero, size: size)))
        forgetHover()
        onBreadcrumb(navigation.count - 2)
    }

    private func forgetHover() { pointer = nil; hovered = nil; onHighlight(nil) }

    private func entryPath(_ tile: Tile) -> String? {
        if case let .entry(entry) = tile.kind { return entry.path }
        return nil
    }

    private func menu(at point: CGPoint) -> [SpaceMapTreemapInputBridge.MenuItem] {
        guard let tile = hit(point), case let .entry(entry) = tile.kind,
              entry.role == .content, !entry.path.isEmpty else { return [] }
        return [
            .init(title: L10n.text("快速查看", "Quick Look"), action: .quickLook),
            .init(title: L10n.text("在访达中显示", "Show in Finder"), action: .reveal),
            .init(title: L10n.text("复制路径", "Copy Path"), action: .copy),
            .init(title: selectionState(entry) == .selected ? L10n.text("取消勾选", "Deselect") : L10n.text("勾选", "Select"),
                  action: .toggle, enabled: !isBusy)
        ]
    }

    private func performMenu(_ action: SpaceMapTreemapInputBridge.MenuAction, at point: CGPoint) {
        guard let tile = hit(point), case let .entry(entry) = tile.kind,
              entry.role == .content, !entry.path.isEmpty else { return }
        switch action {
        case .quickLook: onQuickLook(entry.path)
        case .reveal: onReveal(entry.path)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        case .toggle: if !isBusy { onToggle(entry) }
        }
    }

}

@MainActor
private struct SpaceMapTreemapHoverCard: View {
    let card: SpaceMapTreemapPainter.HoverCard
    let pointer: CGPoint
    let canvas: CGSize
    let tileOrigin: CGPoint
    @Environment(\.colorScheme) private var colorScheme
    @SwiftUI.State private var measuredSize = CGSize.zero

    var body: some View {
        let width = min(220, max(0, canvas.width - 8))
        let frame = SpaceMapTreemapPainter.hoverFrame(at: pointer,
            size: CGSize(width: width, height: measuredSize.height), canvas: canvas, avoiding: tileOrigin)
        // Flattening the adaptive tokens over an opaque base keeps tiles and
        // hatching from showing through the card in either appearance.
        VStack(alignment: .leading, spacing: 4) {
            Text(card.detail).font(.system(size: 13)).foregroundStyle(CareStudioInk.secondary).monospacedDigit()
#if DEBUG
                .layoutProbe("careStudio.spaceLens.hoverCard.detail")
#endif
            Text(card.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(CareStudioInk.primary)
                .lineLimit(1).truncationMode(.middle)
#if DEBUG
                .layoutProbe("careStudio.spaceLens.hoverCard.title")
#endif
            ForEach(Array(card.lines.enumerated()), id: \.offset) { offset, line in
                HStack(alignment: .top, spacing: 4) {
                    if line.locked { Image(systemName: "lock.fill") }
                    Text(line.text).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11)).foregroundStyle(CareStudioInk.secondary)
#if DEBUG
                .layoutProbe("careStudio.spaceLens.hoverCard.line.\(offset)")
#endif
            }
        }
        .padding(12)
        .frame(width: width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { measuredSize = $0 }
        .frame(height: frame.height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 8).fill(colorScheme == .dark ? Color.black : Color.white)
            RoundedRectangle(cornerRadius: 8).fill(CareStudioInk.pillFill)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CareStudioInk.hairline, lineWidth: 1))
        .clipped()
#if DEBUG
        .layoutProbe("careStudio.spaceLens.hoverCard")
#endif
        .shadow(color: (colorScheme == .dark ? CareStudioInk.inverse : CareStudioInk.primary).opacity(0.25), radius: 8, y: 3)
        .position(x: frame.midX, y: frame.midY)
    }
}
