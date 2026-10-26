import SwiftUI

/// Presentation decisions shared by the Canvas and pure tests. No geometry
/// or style here can initiate a navigation or a file operation.
enum SpaceMapTreemapPainter {
    typealias Tile = SpaceMapTreemapLayout.Tile
    typealias Viewport = SpaceMapTreemapViewState.Viewport

    enum PurposeGroup: String, CaseIterable, Sendable {
        case development, caches, personal, other

        init(_ purpose: SpaceMapPurpose) {
            switch purpose {
            case .code, .toolchain, .git, .agentWorkspace: self = .development
            case .cache: self = .caches
            case .media, .documents, .synced: self = .personal
            case .other: self = .other
            }
        }

        var title: String {
            switch self {
            case .development: L10n.text("开发", "Development")
            case .caches: L10n.text("缓存", "Caches")
            case .personal: L10n.text("个人内容", "Personal")
            case .other: L10n.text("其他", "Other")
            }
        }

        var purposes: [SpaceMapPurpose] {
            switch self {
            case .development: [.code, .toolchain, .git, .agentWorkspace]
            case .caches: [.cache]
            case .personal: [.media, .documents, .synced]
            case .other: [.other]
            }
        }

        var help: String {
            title + L10n.text("：", ": ") + purposes.map(\.title).joined(separator: L10n.text("、", ", "))
        }

        // Source: disktree-p3 handoff, round 3 — user-approved colours and
        // the main session's visualisation check, over #30278A / #E4E2F4.
        // All three chromatic pairs pass the difference threshold of 15 in
        // both appearances (the old nine-colour palette's worst pair: 3.3).
        // Light orange/teal contrast is below 3:1 against the panel; retain
        // the visible tile-name labels. Other stays distinct from neutral.
        func hex(dark: Bool) -> UInt32 {
            switch self {
            case .development: dark ? 0x3987E5 : 0x2A78D6
            case .caches: dark ? 0xD95926 : 0xEB6834
            case .personal: dark ? 0x199E70 : 0x1BAF7A
            case .other: dark ? 0x6E6B7B : 0xB6B3C2
            }
        }
    }

    enum Fill: Equatable, Sendable {
        case category(LightfieldFileCategory)
        case purpose(PurposeGroup)
        case neutral

        func color(dark: Bool) -> Color {
            switch self {
            case let .category(category): FeatureLightfieldPalette.fileType(category)
            case let .purpose(group): CareStudioPalette.color(group.hex(dark: dark))
            case .neutral:
                Color(.sRGB, red: (dark ? 58 : 232) / 255,
                      green: (dark ? 58 : 232) / 255, blue: (dark ? 66 : 238) / 255)
            }
        }
    }

    struct LegendItem: Identifiable, Equatable, Sendable {
        let fill: Fill
        var id: String {
            switch fill {
            case let .category(category): "type." + category.rawValue
            case let .purpose(purpose): "purpose." + purpose.rawValue
            case .neutral: "neutral"
            }
        }
        var title: String {
            switch fill {
            case let .category(category): category.title
            case let .purpose(purpose): purpose.title
            case .neutral: L10n.text("其他", "Other")
            }
        }
        var help: String {
            if case let .purpose(group) = fill { return group.help }
            return title
        }
    }

    static func legendItems(mode: SpaceMapColorMode) -> [LegendItem] {
        switch mode {
        case .type: LightfieldFileCategory.allCases.map { LegendItem(fill: .category($0)) }
        case .purpose: PurposeGroup.allCases.map { LegendItem(fill: .purpose($0)) }
        }
    }

    static func fill(for entry: StorageTreemapEntry, mode: SpaceMapColorMode, purposes: SpaceMapPurposeMap?) -> Fill {
        guard entry.role == .content else { return .neutral }
        guard mode == .purpose, let purposes else { return .category(LightfieldFileCategory.category(entry.contentCategory)) }
        return .purpose(PurposeGroup(purpose(for: entry, in: purposes)))
    }

    private static func purpose(for entry: StorageTreemapEntry, in purposes: SpaceMapPurposeMap) -> SpaceMapPurpose {
        purposes.purpose(atPath: entry.isDirectory ? entry.path : DiskScanner.storageMapParentPath(entry.path))
    }

    struct Decoration: Equatable, Sendable {
        let fill: Fill
        /// Positive mixes with white; negative mixes with black.
        let shade: Double
        let hatches: Bool
        let estimated: Bool
    }

    enum Outline: Int, CaseIterable, Sendable {
        case checked, hovered, selected
        var width: CGFloat { self == .selected ? 2 : 1.5 }
        var color: Color {
            switch self {
            case .checked: CareStudioInk.primary.opacity(0.6)
            case .hovered: CareStudioInk.secondary
            case .selected: CareStudioInk.primary
            }
        }
    }

    struct Label: Equatable, Sendable {
        enum Weight: Hashable, Sendable { case semibold, medium }
        let id: String
        let clip: CGRect
        let nameFrame: CGRect
        let sizeFrame: CGRect?
        let name: String
        let size: String
        let fontSize: CGFloat
        let weight: Weight
        let sizeOnRight: Bool
    }

    struct HoverCard: Equatable, Sendable {
        struct Line: Equatable, Sendable {
            let text: String
            var locked = false
        }
        let title: String
        let detail: String
        let lines: [Line]
    }

    struct HoverPresentation {
        let ids: Set<String>
        let card: HoverCard?
    }

    static func checkedIDs(tiles: [Tile], paths: Set<String>) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        return Set(tiles.compactMap { tile in
            guard case let .entry(entry) = tile.kind, entry.role == .content, paths.contains(entry.path) else { return nil }
            return SpaceMapTreemapViewState.id(tile)
        })
    }

    /// Only a hover needs the policy. Drawing every other tile uses cached IDs.
    static func hoverPresentation(for tile: Tile?, highlightedID: String?, snapshot: StorageMapDirectorySnapshot,
                                  index: StorageMapAnalysisIndex, purposes: SpaceMapPurposeMap?,
                                  colorMode: SpaceMapColorMode = .type,
                                  selectionState: (StorageTreemapEntry) -> FileAnalysisTrashSelectionState) -> HoverPresentation {
        var ids = Set<String>()
        if let highlightedID { ids.insert(highlightedID) }
        guard let tile else { return HoverPresentation(ids: ids, card: nil) }
        ids.insert(SpaceMapTreemapViewState.id(tile))
        let selection: FileAnalysisTrashSelectionState
        if case let .entry(entry) = tile.kind, entry.role == .content { selection = selectionState(entry) }
        else { selection = .available }
        return HoverPresentation(ids: ids, card: hoverCard(for: tile, totalBytes: snapshot.measuredBytes,
            index: index, purposes: purposes, selection: selection, colorMode: colorMode))
    }

    static func sizeFits(measuredWidth: CGFloat, availableWidth: CGFloat) -> Bool {
        availableWidth > 0 && measuredWidth <= availableWidth
    }

    static func truncatedName(_ text: String, width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard width > 0 else { return "" }
        if measure(text) <= width { return text }
        let ellipsis = "…"
        guard measure(ellipsis) <= width else { return "" }
        let characters = Array(text)
        var low = 0
        var high = max(0, characters.count - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if measure(String(characters.prefix(middle)) + ellipsis) <= width { low = middle }
            else { high = middle - 1 }
        }
        return low > 0 ? String(characters.prefix(low)) + ellipsis : ""
    }

    static func decoration(for tile: Tile, dark: Bool, purposes: SpaceMapPurposeMap?, colorMode: SpaceMapColorMode = .type) -> Decoration {
        guard case let .entry(entry) = tile.kind else {
            return Decoration(fill: .neutral, shade: 0, hatches: false, estimated: false)
        }
        guard entry.role == .content else {
            return Decoration(fill: .neutral, shade: 0, hatches: false, estimated: entry.isEstimated)
        }
        return Decoration(fill: fill(for: entry, mode: colorMode, purposes: purposes),
                          shade: Double(min(3, max(0, tile.depth))) * (dark ? 0.07 : -0.07),
                          hatches: entry.isDirectory && purposes?.reclaimReason(atPath: entry.path) != nil,
                          estimated: entry.isEstimated)
    }

    static func outlines(checked: Bool, hovered: Bool, selected: Bool) -> [Outline] {
        Outline.allCases.filter {
            switch $0 {
            case .checked: checked
            case .hovered: hovered
            case .selected: selected
            }
        }
    }

    static func checkedBadgeFrame(for tile: Tile, in frame: CGRect, checkedIDs: Set<String>) -> CGRect? {
        guard case let .entry(entry) = tile.kind, entry.role == .content,
              checkedIDs.contains(SpaceMapTreemapViewState.id(tile)), frame.width >= 22, frame.height >= 22 else { return nil }
        return CGRect(x: frame.maxX - 18, y: frame.maxY - 18, width: 14, height: 14)
    }

    static func warningFrame(in frame: CGRect) -> CGRect? {
        guard frame.width >= 9, frame.height >= 9 else { return nil }
        return CGRect(x: max(frame.minX + 1, frame.maxX - 10), y: frame.minY + 1, width: 7, height: 7)
    }

    static func markerBorder(dark: Bool) -> Color { (dark ? Color.black : Color.white).opacity(0.35) }

    static func snapped(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(1, scale)
        let x = (rect.minX * scale).rounded() / scale
        let y = (rect.minY * scale).rounded() / scale
        return CGRect(x: x, y: y, width: max(0, (rect.maxX * scale).rounded() / scale - x),
                      height: max(0, (rect.maxY * scale).rounded() / scale - y))
    }

    static func labels(tiles: [Tile], viewport: Viewport, canvas: CGRect,
                       transform: @escaping (CGRect) -> CGRect = { $0 }) -> [Label] {
        tiles.enumerated().sorted {
            let a = $0.element.frame, b = $1.element.frame
            let aa = a.width * a.height, ba = b.width * b.height
            return aa == ba ? $0.offset < $1.offset : aa > ba
        }.lazy.compactMap { _, tile -> Label? in
            let screen = transform(viewport.project(tile.frame))
            let owned = transform(viewport.project(tile.header ?? tile.frame))
            guard screen.intersects(canvas), owned.width >= 44, owned.height >= 15 else { return nil }
            let clip = owned.intersection(screen)
            let inset = clip.insetBy(dx: 4, dy: 1)
            let name: String
            let bytes: Int64
            switch tile.kind {
            case let .entry(entry): name = entry.title; bytes = entry.sizeBytes
            case let .others(_, count, size): name = moreTitle(count); bytes = size
            }
            let font: CGFloat = tile.depth == 0 ? 12 : 11
            let right = tile.header != nil && inset.width >= 125
            let showsSize = right || tile.header == nil && inset.height >= 34
            let sizeWidth = min(82, inset.width * 0.43)
            let lineHeight = min(inset.height, font + 3)
            return Label(id: SpaceMapTreemapViewState.id(tile), clip: clip,
                nameFrame: CGRect(x: inset.minX, y: inset.minY,
                                  width: max(0, inset.width - (right ? sizeWidth + 5 : 0)), height: lineHeight),
                sizeFrame: showsSize ? CGRect(x: right ? inset.maxX - sizeWidth : inset.minX,
                    y: right ? inset.minY : inset.minY + lineHeight + 2,
                    width: right ? sizeWidth : inset.width, height: lineHeight) : nil,
                name: name, size: ByteFormat.storageString(bytes), fontSize: font,
                weight: tile.depth == 0 ? .semibold : .medium, sizeOnRight: right)
        }.prefix(150).map { $0 }
    }

    static func hoverCard(for tile: Tile, totalBytes: Int64, index: StorageMapAnalysisIndex,
                          purposes: SpaceMapPurposeMap?, selection: FileAnalysisTrashSelectionState,
                          colorMode: SpaceMapColorMode = .type) -> HoverCard {
        switch tile.kind {
        case let .others(_, count, bytes):
            return HoverCard(title: moreTitle(count),
                detail: L10n.text("\(moreTitle(count)) · 共 \(ByteFormat.storageString(bytes))",
                                  "\(moreTitle(count)) · \(ByteFormat.storageString(bytes)) total"), lines: [])
        case let .entry(entry):
            let size = ByteFormat.storageString(entry.sizeBytes)
            guard entry.role == .content else { return HoverCard(title: entry.title, detail: size, lines: []) }
            let share = totalBytes > 0 ? Double(entry.sizeBytes) / Double(totalBytes) * 100 : 0
            var lines: [HoverCard.Line] = []
            if entry.isDirectory, let count = index.directories[entry.path]?.descendantItemCount {
                lines.append(.init(text: L10n.text("\(count) 项", count == 1 ? "1 item" : "\(count) items")))
            }
            lines.append(.init(text: LightfieldFileCategory.category(entry.contentCategory).title))
            if let purposes {
                let purpose = purpose(for: entry, in: purposes)
                let group = PurposeGroup(purpose)
                let title = colorMode == .purpose && group.purposes.count > 1
                    ? L10n.text("\(purpose.title)（\(group.title)）", "\(purpose.title) (\(group.title))")
                    : purpose.title
                lines.append(.init(text: L10n.text("用途：\(title)", "Purpose: \(title)")))
            }
            if let reason = purposes?.reclaimReason(atPath: entry.path) { lines.append(.init(text: reason.title)) }
            let locked: Bool
            if case .blocked = selection { locked = true } else { locked = false }
            lines.append(.init(text: FileAnalysisTrashPresentation.checkboxHelp(state: selection), locked: locked))
            if entry.isEstimated { lines.append(.init(text: L10n.text("估算", "Estimated"))) }
            return HoverCard(title: entry.title, detail: size + " · " + String(format: "%.1f%%", share), lines: lines)
        }
    }

    static func hoverFrame(at pointer: CGPoint, size: CGSize, canvas: CGSize, avoiding tileOrigin: CGPoint? = nil) -> CGRect {
        let width = min(220, size.width, max(0, canvas.width - 8))
        let height = min(size.height, max(0, canvas.height - 8))
        var frame = CGRect(x: max(4, min(pointer.x + 14, canvas.width - width - 4)),
                           y: max(4, min(pointer.y + 14, canvas.height - height - 4)), width: width, height: height)
        if let tileOrigin, frame.contains(tileOrigin) {
            let bounds = CGRect(x: 4, y: 4, width: max(0, canvas.width - 8), height: max(0, canvas.height - 8))
            // Clamping near an edge must not cover the hovered tile's name origin.
            let candidates = [CGPoint(x: tileOrigin.x + 14, y: frame.minY),
                              CGPoint(x: tileOrigin.x - width - 14, y: frame.minY),
                              CGPoint(x: frame.minX, y: tileOrigin.y + 14),
                              CGPoint(x: frame.minX, y: tileOrigin.y - height - 14)]
            if let origin = candidates.first(where: { bounds.contains(CGRect(origin: $0, size: frame.size)) }) {
                frame.origin = origin
            }
        }
        return frame
    }

    static func accessibilitySummary(title: String, entries: [StorageTreemapEntry]) -> String {
        let largest = entries.filter { $0.role == .content && $0.sizeBytes > 0 }.sorted {
            $0.sizeBytes == $1.sizeBytes ? $0.id < $1.id : $0.sizeBytes > $1.sizeBytes
        }.prefix(3).map { $0.title + " " + ByteFormat.storageString($0.sizeBytes) }
        guard !largest.isEmpty else { return title + L10n.text(" · 没有已索引的项目", " · No indexed items") }
        return title + L10n.text(" · 最大的三项：", " · Largest three: ")
            + largest.joined(separator: L10n.text("、", ", "))
    }

    static func moreTitle(_ count: Int) -> String { L10n.text("+\(count) 项", "+\(count) more") }
}

/// This layer also supports offscreen performance measurement. It has no
/// input bridge, focus state or window dependency.
struct SpaceMapTreemapDrawing: View, Equatable {
    let tiles: [SpaceMapTreemapLayout.Tile]
    let layoutKey: SpaceMapTreemapSource.Key?
    var viewport = SpaceMapTreemapViewState.Viewport()
    var transition: SpaceMapTreemapViewState.Transition?
    var time: TimeInterval = 0
    var purposes: SpaceMapPurposeMap?
    var classificationVersion: UInt64?
    var colorMode: SpaceMapColorMode = .type
    var checkedIDs: Set<String> = []
    var hoveredIDs: Set<String> = []
    var selectedID: String?
    var dark = true
    var displayScale: CGFloat = 2
    var labelCache = SpaceMapTreemapLabelCache()

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layoutKey == rhs.layoutKey && lhs.classificationVersion == rhs.classificationVersion && lhs.colorMode == rhs.colorMode
            && lhs.viewport == rhs.viewport && lhs.transition == rhs.transition && lhs.time == rhs.time
            && lhs.checkedIDs == rhs.checkedIDs && lhs.hoveredIDs == rhs.hoveredIDs && lhs.selectedID == rhs.selectedID
            && lhs.dark == rhs.dark && lhs.displayScale == rhs.displayScale
    }

    var body: some View {
        Canvas { context, size in
            paint(context, size: size)
        }
        .accessibilityHidden(true)
    }

    private func paint(_ context: GraphicsContext, size: CGSize) {
        typealias Painter = SpaceMapTreemapPainter
        func transform(_ rect: CGRect) -> CGRect { transition?.sample(rect, at: time) ?? rect }
        var outlines: [(Painter.Outline, CGRect)] = []
        var hatches: [CGRect] = []
        var warnings: [CGRect] = []
        var badges: [CGRect] = []
        for tile in tiles {
            let frame = Painter.snapped(transform(viewport.project(tile.frame)), scale: displayScale)
            guard frame.intersects(CGRect(origin: .zero, size: size)) else { continue }
            let decoration = Painter.decoration(for: tile, dark: dark, purposes: purposes, colorMode: colorMode)
            context.fill(Path(frame), with: .color(decoration.fill.color(dark: dark)))
            if decoration.shade != 0 {
                context.fill(Path(frame), with: .color((decoration.shade > 0 ? Color.white : Color.black)
                    .opacity(abs(decoration.shade))))
            }
            if decoration.hatches { hatches.append(frame) }
            if decoration.estimated, let warning = Painter.warningFrame(in: frame) { warnings.append(warning) }
            if let badge = Painter.checkedBadgeFrame(for: tile, in: frame, checkedIDs: checkedIDs) { badges.append(badge) }
            let id = SpaceMapTreemapViewState.id(tile)
            for outline in Painter.outlines(checked: checkedIDs.contains(id), hovered: hoveredIDs.contains(id), selected: selectedID == id) {
                outlines.append((outline, frame))
            }
        }
        // One translucent hatch covers the outermost matching directory;
        // nested reclaimable directories must not multiply its opacity.
        var hatched: [CGRect] = []
        for frame in hatches where !hatched.contains(where: { $0.contains(frame) }) {
            hatched.append(frame)
            var ctx = context
            ctx.clip(to: Path(frame))
            var path = Path()
            let visible = frame.intersection(CGRect(origin: .zero, size: size))
            var x = visible.minX - visible.height
            while x < visible.maxX {
                path.move(to: CGPoint(x: x, y: visible.maxY))
                path.addLine(to: CGPoint(x: x + visible.height, y: visible.minY))
                x += 6
            }
            ctx.stroke(path, with: .color(CareStudioInk.primary.opacity(0.12)), lineWidth: 1)
        }
        for label in Painter.labels(tiles: tiles, viewport: viewport, canvas: CGRect(origin: .zero, size: size), transform: transform) {
            var ctx = context
            ctx.clip(to: Path(label.clip))
            let textColor = dark ? Color.white.opacity(0.96) : Color.black.opacity(0.9)
            let font = Font.system(size: label.fontSize, weight: label.weight == .semibold ? .semibold : .medium)
            let name = labelCache.name(for: label, transitioning: transition != nil) { text in
                ctx.resolve(Text(text).font(font)).measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
            }
            var nameContext = ctx
            nameContext.clip(to: Path(label.nameFrame))
            nameContext.draw(Text(name).font(font)
                .foregroundColor(textColor), at: label.nameFrame.origin, anchor: .topLeading)
            if let frame = label.sizeFrame {
                let sizeFont: CGFloat = 10
                let sizeText = Text(label.size).font(.system(size: sizeFont)).monospacedDigit()
                if labelCache.sizeFits(label.size, fontSize: sizeFont, width: frame.width, transitioning: transition != nil,
                    measure: { _ in ctx.resolve(sizeText).measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width }) {
                    var sizeContext = ctx
                    sizeContext.clip(to: Path(frame))
                    sizeContext.draw(sizeText.foregroundColor(textColor.opacity(0.8)),
                        at: CGPoint(x: label.sizeOnRight ? frame.maxX : frame.minX, y: frame.minY),
                        anchor: label.sizeOnRight ? .topTrailing : .topLeading)
                }
            }
        }
        for (outline, frame) in outlines.sorted(by: { $0.0.rawValue < $1.0.rawValue }) {
            context.stroke(Path(frame.insetBy(dx: outline.width / 2, dy: outline.width / 2)),
                           with: .color(outline.color), lineWidth: outline.width)
        }
        // Markers share the final pass so descendants cannot cover a parent's check.
        for frame in warnings {
            context.fill(Path(ellipseIn: frame), with: .color(FeatureLightfieldPalette.resolve(dark ? .dark : .light).warningColor))
            context.stroke(Path(ellipseIn: frame.insetBy(dx: 0.5, dy: 0.5)),
                           with: .color(Painter.markerBorder(dark: dark)), lineWidth: 1)
        }
        for frame in badges {
            context.fill(Path(ellipseIn: frame), with: .color(FeatureLightfieldPalette.accent(.largeFiles)))
            context.stroke(Path(ellipseIn: frame.insetBy(dx: 0.5, dy: 0.5)),
                           with: .color(Painter.markerBorder(dark: dark)), lineWidth: 1)
            context.draw(Text(Image(systemName: "checkmark")).font(.system(size: 9, weight: .bold)).foregroundColor(.white),
                         at: CGPoint(x: frame.midX, y: frame.midY))
        }
    }
}

/// The drawing view retains label measurements across hover and animation updates.
@MainActor
final class SpaceMapTreemapLabelCache {
    private struct Key: Hashable {
        let text: String
        let fontSize: CGFloat
        let weight: SpaceMapTreemapPainter.Label.Weight
        let width: Int
    }
    private struct SizeKey: Hashable {
        let text: String
        let fontSize: CGFloat
        let width: CGFloat
    }
    private var names: [Key: String] = [:]
    private var sizes: [SizeKey: Bool] = [:]
    private let limit: Int
    init(limit: Int = 2_000) { self.limit = max(1, limit) }
    var count: Int { names.count + sizes.count }

    func name(for label: SpaceMapTreemapPainter.Label, transitioning: Bool, measure: (String) -> CGFloat) -> String {
        // Round down so every width in a bucket can fit the cached result.
        let key = Key(text: label.name, fontSize: label.fontSize, weight: label.weight,
                      width: Int(max(0, label.nameFrame.width.rounded(.down))))
        if let cached = names[key] { return cached }
        guard !transitioning else { return label.name }
        let name = SpaceMapTreemapPainter.truncatedName(label.name, width: CGFloat(key.width), measure: measure)
        makeRoom()
        names[key] = name
        return name
    }

    func sizeFits(_ text: String, fontSize: CGFloat, width: CGFloat, transitioning: Bool,
                  measure: (String) -> CGFloat) -> Bool {
        guard width > 0 else { return false }
        let key = SizeKey(text: text, fontSize: fontSize, width: width)
        if let cached = sizes[key] { return cached }
        // As for names, do not measure during animation; uncached sizes wait
        // until it finishes, since drawing a clipped number is misleading.
        guard !transitioning else { return false }
        let fits = SpaceMapTreemapPainter.sizeFits(measuredWidth: measure(text), availableWidth: width)
        makeRoom()
        sizes[key] = fits
        return fits
    }

    private func makeRoom() {
        if count >= limit {
            names.removeAll(keepingCapacity: true)
            sizes.removeAll(keepingCapacity: true)
        }
    }
}
