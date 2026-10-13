import SwiftUI

/// UI-V2-SPEC §2.1: one size class for the detail area, measured once at its
/// root (`AdaptivePageViewport`) and shared through the environment. Every
/// boundary keeps 16 pt of hysteresis: a class is entered at its threshold
/// and only left 16 pt below it, so a window dragged across a breakpoint
/// does not flicker between two layouts.
struct PageLayout: Equatable, Sendable {
    enum Width: Int, Comparable, CaseIterable, Sendable {
        case compact, regular, wide, extraWide

        static func < (lhs: Width, rhs: Width) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Height: Int, Comparable, CaseIterable, Sendable {
        case short, regular, tall

        static func < (lhs: Height, rhs: Height) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The page header forms of §2.3.
    enum HeroForm: Equatable, Sendable {
        /// Large windows (wide and tall, or extra wide): 72 pt tile, 30 pt
        /// title, subtitle (main session review of the V0 samples).
        case prominent
        /// 64 pt tile, 28 pt title, subtitle.
        case full
        /// 52 pt tile, 24 pt title, subtitle.
        case regular
        /// About 52 pt high: 32 pt tile, 20 pt title, no subtitle.
        case compact
    }

    /// Landing pages may use the full header; live-data tool pages (memory,
    /// energy, performance) never do, so the data keeps the height (§2.3).
    enum PageRole: Sendable {
        case landing
        case tool
    }

    /// regular, wide and extraWide start at these detail widths.
    static let widthThresholds: [CGFloat] = [720, 1040, 1500]
    /// regular and tall start at these detail heights.
    static let heightThresholds: [CGFloat] = [560, 900]
    /// Full header and large artwork need at least this detail height.
    static let fullHeaderMinimumHeight: CGFloat = 680
    static let hysteresis: CGFloat = 16

    var width: Width
    var height: Height
    /// At least 680 pt tall (with the same hysteresis).
    var allowsFullHeaderHeight: Bool
    var size: CGSize

    init(width: Width, height: Height, allowsFullHeaderHeight: Bool, size: CGSize) {
        self.width = width
        self.height = height
        self.allowsFullHeaderHeight = allowsFullHeaderHeight
        self.size = size
    }

    /// Resolves the classes for `size`. With a `previous` layout the classes
    /// only step down once the size is 16 pt below the boundary.
    static func resolve(size: CGSize, previous: PageLayout? = nil) -> PageLayout {
        let width = finite(size.width)
        let height = finite(size.height)
        let widthIndex = classIndex(width, thresholds: widthThresholds,
                                    previous: previous?.width.rawValue)
        let heightIndex = classIndex(height, thresholds: heightThresholds,
                                     previous: previous?.height.rawValue)
        let fullIndex = classIndex(height, thresholds: [fullHeaderMinimumHeight],
                                   previous: previous.map { $0.allowsFullHeaderHeight ? 1 : 0 })
        return PageLayout(
            width: Width(rawValue: widthIndex) ?? .compact,
            height: Height(rawValue: heightIndex) ?? .short,
            allowsFullHeaderHeight: fullIndex == 1,
            size: CGSize(width: width, height: height)
        )
    }

    /// Upward steps happen at the threshold; downward steps wait until the
    /// value is `hysteresis` below the threshold of the current class.
    static func classIndex(_ value: CGFloat, thresholds: [CGFloat], previous: Int?) -> Int {
        let raw = thresholds.filter { value >= $0 }.count
        guard let previous, previous > raw, previous <= thresholds.count else { return raw }
        var index = previous
        while index > raw, value < thresholds[index - 1] - hysteresis {
            index -= 1
        }
        return index
    }

    private static func finite(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 0
    }

    /// Changes only when a class changes; drives the `standard` animation.
    var classKey: Int {
        width.rawValue * 100 + height.rawValue * 10 + (allowsFullHeaderHeight ? 1 : 0)
    }

    func heroForm(for role: PageRole) -> HeroForm {
        if width == .compact || height == .short { return .compact }
        if role == .landing, width >= .wide, allowsFullHeaderHeight {
            return height == .tall || width == .extraWide ? .prominent : .full
        }
        return .regular
    }

    /// "wide or tall": large windows scale the landing composition up.
    var isLarge: Bool {
        width >= .wide || height == .tall
    }

    /// Large cards, buttons and illustrations (§2.3): a large window that
    /// also has the full-header height. A wide window 560–679 pt tall keeps
    /// the regular sizes, so its options and action still fit.
    var usesLargeComposition: Bool {
        isLarge && allowsFullHeaderHeight && height != .short
    }

    /// §1.4 page margins: compact 16, regular 24, wide 32.
    var pagePadding: CGFloat {
        switch width {
        case .compact: AppDesignTokens.Grid.x2
        case .regular: AppDesignTokens.Grid.x3
        case .wide, .extraWide: AppDesignTokens.Grid.x4
        }
    }

    /// §1.4 card padding: compact 12, regular 16, wide 20.
    var cardPadding: CGFloat {
        switch width {
        case .compact: AppDesignTokens.Grid.x1_5
        case .regular: AppDesignTokens.Grid.x2
        case .wide, .extraWide: AppDesignTokens.Grid.x2_5
        }
    }

    /// §1.4 card spacing: compact 12, otherwise 16.
    var cardSpacing: CGFloat {
        width == .compact ? AppDesignTokens.Grid.x1_5 : AppDesignTokens.Grid.x2
    }

    /// §2.4 maximum content widths: landing compositions stop at about
    /// 1440 pt (main session review: 1240 left large windows empty),
    /// dashboards and lists at 1400; the glow still fills the page.
    static let landingMaxWidth: CGFloat = 1_440
    static let contentMaxWidth: CGFloat = 1_400
    /// §2.4 readable line length for paragraphs.
    static let readableLineWidth: CGFloat = 720
}

private struct PageLayoutEnvironmentKey: EnvironmentKey {
    static let defaultValue: PageLayout? = nil
}

extension EnvironmentValues {
    /// Set by `AdaptivePageViewport`; `nil` when a view is hosted alone
    /// (previews, tests), in which case views resolve from their own size.
    var pageLayout: PageLayout? {
        get { self[PageLayoutEnvironmentKey.self] }
        set { self[PageLayoutEnvironmentKey.self] = newValue }
    }
}

/// A page that owns its scrolling (the shared landing shell, the memory
/// page) asks the viewport for exactly the visible height instead of the
/// 468 pt minimum page.
struct PageOwnsScrollingPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    func pageOwnsScrolling(_ owns: Bool = true) -> some View {
        preference(key: PageOwnsScrollingPreferenceKey.self, value: owns)
    }
}

// MARK: - Sidebar presentation (§2.2)

enum SidebarPresentation: String, Equatable, Sendable {
    /// Full sidebar, 196–228 pt.
    case full
    /// About 64 pt: tiles only, names in tooltips, separators for groups.
    case rail

    static let railThreshold: CGFloat = 960

    var minimumWidth: CGFloat { self == .full ? AppDesignTokens.Layout.sidebarMinimumWidth : railWidth }
    var idealWidth: CGFloat { self == .full ? AppDesignTokens.Layout.sidebarExpandedWidth : railWidth }
    var maximumWidth: CGFloat { self == .full ? AppDesignTokens.Layout.sidebarMaximumWidth : railWidth }
    var railWidth: CGFloat { 64 }

    /// Window width based mode with the shared 16 pt hysteresis: the rail
    /// appears below 944 pt once the sidebar is full, and the full sidebar
    /// returns at 960 pt.
    static func automatic(windowWidth: CGFloat, previous: SidebarPresentation?) -> SidebarPresentation {
        let width = windowWidth.isFinite ? windowWidth : 0
        let index = PageLayout.classIndex(
            width,
            thresholds: [railThreshold],
            previous: previous.map { $0 == .full ? 1 : 0 }
        )
        return index == 1 ? .full : .rail
    }
}

/// The window keeps the automatic mode and the user's manual choice. A
/// manual choice holds until the window crosses the threshold again (§2.2).
struct SidebarPresentationState: Equatable, Sendable {
    private(set) var automatic: SidebarPresentation = .full
    private(set) var userChoice: SidebarPresentation?

    var effective: SidebarPresentation { userChoice ?? automatic }

    mutating func update(windowWidth: CGFloat) {
        let next = SidebarPresentation.automatic(windowWidth: windowWidth, previous: automatic)
        if next != automatic {
            automatic = next
            userChoice = nil
        }
    }

    mutating func toggle() {
        userChoice = effective == .full ? .rail : .full
    }
}

// MARK: - Adaptive containers (§2.4)

/// Two panes at about 58 / 42 side by side from `regular` width, stacked in
/// `compact`.
struct AdaptivePane<Primary: View, Secondary: View>: View {
    @Environment(\.pageLayout) private var pageLayout
    var primaryFraction: CGFloat = 0.58
    var spacing: CGFloat?
    var alignment: VerticalAlignment = .top
    @ViewBuilder let primary: Primary
    @ViewBuilder let secondary: Secondary

    var body: some View {
        let layout = pageLayout
        let gap = spacing ?? layout?.cardSpacing ?? AppDesignTokens.Grid.x2
        if (layout?.width ?? .regular) == .compact {
            VStack(alignment: .leading, spacing: gap) {
                primary
                secondary
            }
        } else {
            AdaptivePaneSplitLayout(primaryFraction: primaryFraction, spacing: gap, alignment: alignment) {
                primary
                secondary
            }
        }
    }
}

/// Splits the proposed width by fraction; heights follow the content.
private struct AdaptivePaneSplitLayout: Layout {
    let primaryFraction: CGFloat
    let spacing: CGFloat
    let alignment: VerticalAlignment

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let widths = columnWidths(total: width)
        let heights = zip(subviews, widths).map { subview, columnWidth in
            subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: proposal.height)).height
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(total: bounds.width)
        var x = bounds.minX
        for (subview, columnWidth) in zip(subviews, widths) {
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: bounds.height))
            let y: CGFloat = switch alignment {
            case .center: bounds.midY - size.height / 2
            case .bottom: bounds.maxY - size.height
            default: bounds.minY
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: columnWidth, height: size.height))
            x += columnWidth + spacing
        }
    }

    private func columnWidths(total: CGFloat) -> [CGFloat] {
        let usable = max(0, total - spacing)
        let primary = (usable * min(0.85, max(0.15, primaryFraction))).rounded()
        return [primary, max(0, usable - primary)]
    }
}

/// Columns of at least `minimumColumnWidth` (260 pt), 1–4 of them, and never
/// a lonely last row: four cards become 4, 2 + 2 or 1 per row, never 3 + 1
/// (§2.4 "不排成 3+1").
struct AdaptiveCardGrid: Layout {
    var minimumColumnWidth: CGFloat = 260
    var maximumColumns = 4
    var spacing: CGFloat = AppDesignTokens.Grid.x2

    static func columnCount(
        itemCount: Int,
        availableWidth: CGFloat,
        minimumColumnWidth: CGFloat,
        maximumColumns: Int,
        spacing: CGFloat
    ) -> Int {
        guard itemCount > 0, availableWidth.isFinite, availableWidth > 0 else { return 1 }
        let fitting = max(1, min(maximumColumns, Int((availableWidth + spacing) / (minimumColumnWidth + spacing))))
        if itemCount <= fitting { return itemCount }
        guard fitting >= 2 else { return 1 }
        // Complete rows first (4 → 2 + 2, 6 → 3 + 3) ...
        for columns in stride(from: fitting, through: 2, by: -1) where itemCount % columns == 0 {
            return columns
        }
        // ... then a last row that is more than half full (5 → 3 + 2).
        for columns in stride(from: fitting, through: 2, by: -1)
        where Double(itemCount % columns) / Double(columns) > 0.5 {
            return columns
        }
        // Three items never become 2 + 1; long lists keep the widest grid.
        return itemCount > fitting * 2 ? fitting : 1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minimumColumnWidth * 2 + spacing)
        let columns = Self.columnCount(itemCount: subviews.count, availableWidth: width,
                                       minimumColumnWidth: minimumColumnWidth,
                                       maximumColumns: maximumColumns, spacing: spacing)
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let rows = rowHeights(subviews: subviews, columns: columns, columnWidth: columnWidth)
        let height = rows.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = Self.columnCount(itemCount: subviews.count, availableWidth: bounds.width,
                                       minimumColumnWidth: minimumColumnWidth,
                                       maximumColumns: maximumColumns, spacing: spacing)
        let columnWidth = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let rows = rowHeights(subviews: subviews, columns: columns, columnWidth: columnWidth)
        var y = bounds.minY
        for (rowIndex, rowHeight) in rows.enumerated() {
            for column in 0..<columns {
                let index = rowIndex * columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (columnWidth + spacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: columnWidth, height: rowHeight)
                )
            }
            y += rowHeight + spacing
        }
    }

    private func rowHeights(subviews: Subviews, columns: Int, columnWidth: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { start in
            (start..<min(start + columns, subviews.count)).map {
                subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            }.max() ?? 0
        }
    }
}

/// §2.4 list column priority: P1 always (icon, name, size), P2 from
/// `regular` (category, date), P3 from `wide` (path, extra details).
enum ListColumnPriority: Int, Comparable, Sendable {
    case p1 = 1
    case p2 = 2
    case p3 = 3

    static func < (lhs: ListColumnPriority, rhs: ListColumnPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    func isVisible(in width: PageLayout.Width) -> Bool {
        switch self {
        case .p1: true
        case .p2: width >= .regular
        case .p3: width >= .wide
        }
    }

    static func visibleColumns(in width: PageLayout.Width) -> [ListColumnPriority] {
        [.p1, .p2, .p3].filter { $0.isVisible(in: width) }
    }
}

private struct ListColumnModifier: ViewModifier {
    @Environment(\.pageLayout) private var pageLayout
    let priority: ListColumnPriority

    func body(content: Content) -> some View {
        if priority.isVisible(in: pageLayout?.width ?? .wide) {
            content
        }
    }
}

extension View {
    /// Hides this column below its width class (§2.4).
    func listColumn(_ priority: ListColumnPriority) -> some View {
        modifier(ListColumnModifier(priority: priority))
    }
}

/// §2.4 pinned bottom bar: the primary action never scrolls away. Leading
/// is the selection summary, trailing the actions. macOS 26 uses Liquid
/// Glass; earlier systems and Reduce Transparency use the opaque elevated
/// surface (views keep no local materials). Attach with
/// `.safeAreaInset(edge: .bottom)` or as the last row of a page.
struct PinnedActionBar<Summary: View, Actions: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.pageLayout) private var pageLayout
    @AppSurfaces private var surfaces
    @ViewBuilder let summary: Summary
    @ViewBuilder let actions: Actions

    var body: some View {
        let compact = (pageLayout?.width ?? .regular) == .compact
        // Short windows (§2.1, down to a 338 pt tile) get a 44 pt bar.
        let short = pageLayout?.height == .short
        HStack(alignment: .center, spacing: AppDesignTokens.Grid.x1_5) {
            summary
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(compact ? 0 : 1)
            HStack(spacing: AppDesignTokens.Grid.x1) {
                actions
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, short ? AppDesignTokens.Grid.x1_5 : AppDesignTokens.Grid.x2)
        .padding(.vertical, short ? AppDesignTokens.Grid.x1 : AppDesignTokens.Grid.x1_5)
        .frame(maxWidth: .infinity, minHeight: short ? 44 : 56)
        .background { barBackground }
        .overlay {
            RoundedRectangle(cornerRadius: AppDesignTokens.Corner.card, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [surfaces.strokeTop, surfaces.strokeBottom],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(surfaces.isNight ? 0.35 : 0.08), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var barBackground: some View {
        let shape = RoundedRectangle(cornerRadius: AppDesignTokens.Corner.card, style: .continuous)
        if #available(macOS 26.0, *), !reduceTransparency {
            shape.fill(surfaces.cardElevated.opacity(0.55))
                .glassEffect(.regular, in: shape)
        } else {
            shape.fill(surfaces.cardElevated)
        }
    }
}
