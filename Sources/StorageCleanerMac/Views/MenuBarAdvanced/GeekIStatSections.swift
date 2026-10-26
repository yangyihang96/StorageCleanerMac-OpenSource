import SwiftUI

/// D119: iStat Menus 7.30 module menus (level two), in points inside a card.
/// Measured on the settings previews (`round2/istat/istat-preview-*.jpg`)
/// and the static section constants (`itemWithConfig:`, `-[CPUMenu build]`).
/// Rows are 15 pt on a 17 pt pitch; a section's title is the card title row
/// at (8, 5) (`GeekIStatCardGeometry`).
enum GeekIStatSectionGeometry {
    static let rowHeight: CGFloat = 15
    static let rowPitch: CGFloat = 17
    static var rowGap: CGFloat { rowPitch - rowHeight }

    /// Row `index`: from 5 in an untitled section, below the title row (22)
    /// in a titled one.
    static func rowTop(_ index: Int, titled: Bool) -> CGFloat {
        (titled ? 22 : 5) + rowPitch * CGFloat(max(0, index))
    }

    /// n rows: 8 + 17n untitled (memory composition, swap activity), 24 + 17n
    /// under a title (a sensor group with one row is 41).
    static func rowsHeight(_ count: Int, titled: Bool) -> CGFloat {
        (titled ? 24 : 8) + rowPitch * CGFloat(max(1, count))
    }

    /// A title row with its value on the right (load, uptime, energy mode,
    /// an interface): 25.
    static let singleRowHeight: CGFloat = 25

    /// A process section: the title row, then n rows from 22; 25 + 17n (76
    /// for three rows on the preview; the static `count * 17 + 26` reads one
    /// point taller).
    static func processesHeight(_ count: Int) -> CGFloat {
        25 + rowPitch * CGFloat(max(1, count))
    }

    /// A process row: the 16 pt icon 9 pt from the card's edge, the name
    /// from 28, the value right-aligned at the 8 pt inset.
    static let processIconLeading: CGFloat = 9
    static let processIconSize: CGFloat = 16
    static var processNameSpacing: CGFloat { 28 - processIconLeading - processIconSize }

    /// A title row and an 8 pt bar at 24 (swap, battery, keyboard): 40.
    static let barSectionHeight: CGFloat = 40

    /// The battery menu's charge chart: 80, the bars from 8 to 60 and the
    /// connection rail from 64 to 72 (`BBRBatteryMenuBatteryGraphSection
    /// drawRect:`: graph (8, H − 20, W − 14, H − 28), rail at H − 16). D132:
    /// the bars started at 6 (D119, 2x preview).
    static let chargeChartHeight: CGFloat = 80
    static let chargeChartTop: CGFloat = 8
    static let chargeChartBottomInset: CGFloat = 8

    // GPU: the title row, then four 54 pt rings (line 4) from 24, spread over
    // the content width.
    static let gpuHeight: CGFloat = 87
    static let gpuRingSize: CGFloat = 54
    static let gpuRingLineWidth: CGFloat = 4
    static let gpuRingTop: CGFloat = 24
    static let gpuValueFontSize: CGFloat = 14
    static let gpuLabelFontSize: CGFloat = 10
}

/// D121: a history page (level three) is iStat's graph card, 375 × 200 in
/// a 391 pt window (`MiniWindowStyleTokens.history…`). Readings we keep
/// beside the history (current values, totals, hardware ranges) are
/// sections below the card, 7 pt apart as on the other levels.
enum GeekIStatHistoryGeometry {
    /// The page: the graph card and the sections of `heights` below it.
    static func pageHeight(belowGraph heights: [CGFloat] = []) -> CGFloat {
        MiniWindowStyleTokens.historyHeight
            + heights.reduce(0) { $0 + MiniWindowStyleTokens.cardSpacing + $1 }
    }

    /// The page with an untitled section of `rowCount` rows below the card.
    static func pageSize(rowCount: Int) -> CGSize {
        CGSize(
            width: MiniWindowStyleTokens.historyWidth,
            height: pageHeight(belowGraph: rowCount > 0 ? [GeekIStatSectionGeometry.rowsHeight(rowCount, titled: false)] : [])
        )
    }

    /// D132: iStat's battery history submenu (`-[BatteryMenu loadItems]`:
    /// `setWidth: 319`, the graph `setHeight: 180`): one card with the other
    /// histories' title row, the bars from 30 to 20 pt above the bottom and
    /// the connection rail from 16 to 8 pt above it; no axis row. It was the
    /// 391 × 216 history page.
    static let batteryPageWidth: CGFloat = 319
    static let batteryCardHeight: CGFloat = 180
    static let batteryPlotTop: CGFloat = 30
    static let batteryPageSize = CGSize(
        width: batteryPageWidth,
        height: batteryCardHeight + 2 * MiniWindowStyleTokens.contentInset
    )

    /// The tooltip (`BBRMenuHistorySubmenuOverlay`): 8 pt beside the
    /// indicator, flipped to the other side 6 pt away when it does not fit;
    /// at most 200 wide, 15 pt rows inside an 8 pt inset, corner 8.
    static let tooltipGap: CGFloat = 8
    static let tooltipFlippedGap: CGFloat = 6
    static let tooltipMaximumWidth: CGFloat = 200
    static let tooltipInset: CGFloat = 8
    static let tooltipRowHeight: CGFloat = 15
    static let tooltipCornerRadius = MiniWindowTooltipStyle.historyCornerRadius
    /// The 2 pt indicator over the hovered bar.
    static let indicatorWidth: CGFloat = 2
}

/// D122: a plain level-three page (iStat's `BBRMenu` submenus without a
/// history: the disk space, uptime, battery and interface menus) is a stack
/// of cards 7 pt apart inside the column's 8 pt inset, 220 wide as iStat's
/// disk space menu (`setWidth: 220`).
enum GeekIStatDetailGeometry {
    static let pageWidth: CGFloat = 220

    /// The page around cards of `heights`.
    static func pageHeight(cards heights: [CGFloat]) -> CGFloat {
        2 * MiniWindowStyleTokens.contentInset
            + heights.reduce(0, +)
            + MiniWindowStyleTokens.cardSpacing * CGFloat(max(0, heights.count - 1))
    }

    static func pageSize(cards heights: [CGFloat], width: CGFloat = pageWidth) -> CGSize {
        CGSize(width: width, height: pageHeight(cards: heights))
    }

    // Stacked groups (`-[CPUMenu updateUptimeSubmenu]`): a major label row
    // above its value row, groups separated by a 7 pt spacer row, 5 pt above
    // the first and below the last.
    static var stackedGroupHeight: CGFloat { 2 * GeekIStatSectionGeometry.rowHeight }
    static let stackedGroupGap: CGFloat = 7

    static func stackedHeight(groupCount: Int) -> CGFloat {
        let count = CGFloat(max(1, groupCount))
        return 2 * GeekIStatCardGeometry.titleTop + count * stackedGroupHeight + (count - 1) * stackedGroupGap
    }

    // Disk space (`BBRDisksMenuSpaceBarSection`): a 200 pt card; a 10 pt ring
    // centered at (W/2, W/2) with radius W/2 − 20; the legend centered inside
    // it, an entry's label row (7 pt dot, 3 pt gap) above its value row, 37
    // pt apart from 48 (three entries) or 66 (two); values in W − 60.
    static let spaceCardHeight: CGFloat = 200
    static let spaceRingLineWidth: CGFloat = 10
    static let spaceRingInset: CGFloat = 20
    static let spaceLegendPitch: CGFloat = 37
    static let spaceLegendDotSize: CGFloat = 7
    static let spaceLegendValueInset: CGFloat = 30

    static func spaceRingRadius(cardWidth: CGFloat) -> CGFloat {
        cardWidth / 2 - spaceRingInset
    }

    static func spaceLegendTop(entryCount: Int) -> CGFloat {
        entryCount >= 3 ? 48 : 66
    }

    // D136: the space section's buttons (`drawRect:`, `mouseDown:`): the
    // Finder icon at (8, 8) and the visibility icon at (W − 24, 8), 16 pt
    // each; a click counts inside the 32 pt square at either top corner.
    static let spaceActionIconSize: CGFloat = 16
    static let spaceActionHitSize: CGFloat = 32
}

/// D122: a note below a reading's rows (what the value means, why it is
/// missing): the caption in the secondary color, wrapping inside the card's
/// insets. iStat's menus carry no notes; ours keep the card language.
struct GeekIStatNoteCard: View {
    let text: String

    /// Three caption lines until the card is measured.
    nonisolated static let estimatedHeight: CGFloat = 52

    var body: some View {
        MiniWindowGroup {
            Text(text)
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// D122: iStat's stacked text section (the uptime menu): untitled groups of
/// a major label (the section-title style) above a value, 7 pt apart.
struct GeekIStatStackedGroupsCard: View {
    struct Entry: Identifiable {
        let title: String
        let value: String
        var help: String? = nil
        var id: String { title }
    }

    let groups: [Entry]

    var body: some View {
        GeekIStatCard(height: GeekIStatDetailGeometry.stackedHeight(groupCount: groups.count)) {
            VStack(alignment: .leading, spacing: GeekIStatDetailGeometry.stackedGroupGap) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        GeekModuleHeader(title: group.title)
                        Text(group.value)
                            .geekIStatValueText()
                            .frame(height: GeekIStatSectionGeometry.rowHeight)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(group.help ?? "")
                    .accessibilityElement(children: .combine)
                }
            }
            .geekIStatLayer(top: GeekIStatCardGeometry.titleTop, alignment: .topLeading)
        }
    }
}

/// A layout that spreads equal items over its width: the first at the
/// leading edge, the last at the trailing edge, as many per row as fit at
/// `minimumSpacing`, rows `rowPitch` apart (iStat's core and GPU rings).
struct GeekIStatSpreadLayout: Layout {
    let itemSize: CGFloat
    var minimumSpacing: CGFloat = 2
    var rowPitch: CGFloat = 0

    static func columns(count: Int, itemSize: CGFloat, minimumSpacing: CGFloat, width: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let fit = Int(((width + minimumSpacing) / (itemSize + minimumSpacing)).rounded(.down))
        return max(1, min(count, fit))
    }

    static func rows(count: Int, columns: Int) -> Int {
        max(1, (max(1, count) + columns - 1) / max(1, columns))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let count = subviews.count
        let width = proposal.width ?? CGFloat(count) * itemSize + CGFloat(max(0, count - 1)) * minimumSpacing
        let columns = Self.columns(count: count, itemSize: itemSize, minimumSpacing: minimumSpacing, width: width)
        let rows = Self.rows(count: count, columns: columns)
        return CGSize(width: width, height: CGFloat(rows - 1) * max(rowPitch, itemSize) + itemSize)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let columns = Self.columns(count: subviews.count, itemSize: itemSize,
                                   minimumSpacing: minimumSpacing, width: bounds.width)
        let pitch = columns > 1 ? (bounds.width - itemSize) / CGFloat(columns - 1) : 0
        for (index, subview) in subviews.enumerated() {
            let column = index % columns
            let row = index / columns
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * pitch,
                            y: bounds.minY + CGFloat(row) * max(rowPitch, itemSize)),
                proposal: ProposedViewSize(width: itemSize, height: itemSize)
            )
        }
    }
}

/// One 15 pt row: the label in the label color on the left, the value in
/// the value color right-aligned; an optional 9 pt legend dot before the
/// label (iStat's legend rows). The caller attaches the row's `.help`.
struct GeekIStatRow: View {
    @Environment(\.displayScale) private var displayScale
    let title: String
    let value: String
    var valueColor: Color = .primary
    var dotColor: Color? = nil
    /// A dot in a track color (memory's Free) gets a hairline so it stays
    /// visible on the card.
    var dotHasOutline = false

    var body: some View {
        HStack(spacing: GeekIStatCardGeometry.legendDotSpacing) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .overlay {
                        if dotHasOutline {
                            Circle().strokeBorder(
                                .tertiary,
                                lineWidth: MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
                            )
                        }
                    }
                    .frame(width: GeekIStatCardGeometry.legendDotSize, height: GeekIStatCardGeometry.legendDotSize)
                    .accessibilityHidden(true)
            }
            Text(title).geekIStatLabelText()
            Spacer(minLength: MiniWindowStyleTokens.inlineSpacing)
            Text(value).geekIStatValueText(valueColor)
        }
        .frame(height: GeekIStatSectionGeometry.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// A section of rows on the 17 pt pitch: an optional title row at (8, 5)
/// with a trailing readout, then `rowCount` rows of 15 pt. The rows are the
/// caller's views (`GeekIStatRow`, hover targets around them …), each 15 pt.
struct GeekIStatRowsCard<Trailing: View, Rows: View>: View {
    let title: String?
    let rowCount: Int
    let trailing: Trailing
    let rows: Rows

    init(
        title: String? = nil,
        rowCount: Int,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder rows: () -> Rows
    ) {
        self.title = title
        self.rowCount = rowCount
        self.trailing = trailing()
        self.rows = rows()
    }

    var body: some View {
        GeekIStatCard(height: GeekIStatSectionGeometry.rowsHeight(rowCount, titled: title != nil)) {
            if let title {
                GeekModuleHeader(title: title) { trailing }
                    .geekIStatLayer(top: GeekIStatCardGeometry.titleTop, height: GeekIStatCardGeometry.titleHeight)
            }
            VStack(spacing: GeekIStatSectionGeometry.rowGap) { rows }
                .geekIStatLayer(top: GeekIStatSectionGeometry.rowTop(0, titled: title != nil), alignment: .top)
        }
    }
}

extension GeekIStatRowsCard where Trailing == EmptyView {
    init(title: String? = nil, rowCount: Int, @ViewBuilder rows: () -> Rows) {
        self.init(title: title, rowCount: rowCount, trailing: { EmptyView() }, rows: rows)
    }
}

/// A 25 pt section of one title row with its value on the right (load,
/// uptime, energy mode, an interface).
struct GeekIStatSingleRowCard<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        GeekIStatCard(height: GeekIStatSectionGeometry.singleRowHeight) {
            GeekModuleHeader(title: title) { trailing }
                .geekIStatLayer(top: GeekIStatCardGeometry.titleTop, height: GeekIStatCardGeometry.titleHeight)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A single-row card's value: 12 pt with monospaced digits in the theme's
/// value color (D135; it was a `Text` in the primary color).
struct GeekIStatSingleRowValue: View {
    let value: String
    var color: Color = .primary

    var body: some View {
        Text(value)
            .font(.system(size: GeekIStatCardGeometry.textFontSize))
            .modifier(GeekIStatTextColor(role: .value, color: color))
            .monospacedDigit()
    }
}

extension GeekIStatSingleRowCard where Trailing == GeekIStatSingleRowValue {
    init(title: String, value: String, valueColor: Color = .primary) {
        self.init(title: title) {
            GeekIStatSingleRowValue(value: value, color: valueColor)
        }
    }
}

/// iStat's process section: the title row (with an optional status and the
/// value-column labels on the right), then the rows from 22 on the 17 pt
/// pitch. The card keeps the height of `rowCapacity` rows, so the page does
/// not grow and shrink with the number of busy processes.
struct GeekIStatProcessCard<Accessory: View, Rows: View>: View {
    let title: String
    var status: String?
    var help: String?
    var columns: [GeekProcessListColumn]
    let rowCapacity: Int
    let accessory: Accessory
    let rows: Rows

    init(
        title: String,
        status: String? = nil,
        help: String? = nil,
        columns: [GeekProcessListColumn] = [],
        rowCapacity: Int,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder rows: () -> Rows
    ) {
        self.title = title
        self.status = status
        self.help = help
        self.columns = columns
        self.rowCapacity = rowCapacity
        self.accessory = accessory()
        self.rows = rows()
    }

    var body: some View {
        GeekIStatProcessSection(rowCapacity: rowCapacity) {
            GeekProcessListHeader(title: title, status: status, help: help, columns: columns) { accessory }
        } rows: {
            rows
        }
    }
}

/// The layout of iStat's process section for a page that builds its own
/// header (the network page's): the header in the title row, the rows from
/// 22 on the 17 pt pitch, the height of `rowCapacity` rows.
struct GeekIStatProcessSection<Header: View, Rows: View>: View {
    let rowCapacity: Int
    let header: Header
    let rows: Rows

    init(rowCapacity: Int, @ViewBuilder header: () -> Header, @ViewBuilder rows: () -> Rows) {
        self.rowCapacity = rowCapacity
        self.header = header()
        self.rows = rows()
    }

    var body: some View {
        GeekIStatCard(height: GeekIStatSectionGeometry.processesHeight(rowCapacity)) {
            header
                .geekIStatLayer(top: GeekIStatCardGeometry.titleTop, height: GeekIStatCardGeometry.titleHeight)
            VStack(spacing: GeekIStatSectionGeometry.rowGap) { rows }
                .geekIStatLayer(
                    top: GeekIStatSectionGeometry.rowTop(0, titled: true),
                    height: CGFloat(max(1, rowCapacity)) * GeekIStatSectionGeometry.rowPitch
                        - GeekIStatSectionGeometry.rowGap,
                    leading: GeekIStatSectionGeometry.processIconLeading,
                    alignment: .top
                )
        }
    }
}

extension GeekIStatProcessCard where Accessory == EmptyView {
    init(
        title: String,
        status: String? = nil,
        help: String? = nil,
        columns: [GeekProcessListColumn] = [],
        rowCapacity: Int,
        @ViewBuilder rows: () -> Rows
    ) {
        self.init(title: title, status: status, help: help, columns: columns, rowCapacity: rowCapacity,
                  accessory: { EmptyView() }, rows: rows)
    }
}

/// A process row inside `GeekIStatProcessCard` (whose row layer starts at
/// the icon, 9 pt from the card's edge): the 16 pt icon, the name from 28,
/// then the values right-aligned at the trailing inset.
struct GeekIStatProcessRow<Values: View>: View {
    let iconPath: String
    var fallbackSymbol = "app.fill"
    let name: String
    let values: Values

    init(iconPath: String, fallbackSymbol: String = "app.fill", name: String, @ViewBuilder values: () -> Values) {
        self.iconPath = iconPath
        self.fallbackSymbol = fallbackSymbol
        self.name = name
        self.values = values()
    }

    var body: some View {
        HStack(spacing: GeekIStatSectionGeometry.processNameSpacing) {
            GeekSecondaryProcessIcon(path: iconPath, fallback: fallbackSymbol)
            Text(name)
                .geekIStatLabelText()
                .truncationMode(.middle)
            Spacer(minLength: MiniWindowStyleTokens.inlineSpacing)
            values
        }
        .frame(height: GeekIStatSectionGeometry.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// The rows area of a process section with nothing to list: a spinner while
/// the first measurement runs, else the given text.
struct GeekIStatProcessPlaceholder: View {
    let isLoading: Bool
    var text = "—"

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text(text).geekIStatLabelText().foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A plain usage ring without text (iStat's core rings): the track and the
/// arc from 12 o'clock clockwise.
struct GeekIStatPlainRing: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.miniWindowVisualMode) private var visualMode
    let progress: Double?
    let tint: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(GeekVisualTokens.ringTrack(for: colorScheme, visualMode: visualMode, palette: panelChromePalette), lineWidth: lineWidth)
            if let progress, progress.isFinite {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .transaction { $0.animation = nil }
    }
}
