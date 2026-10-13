import AppKit
import SwiftUI

/// Equal slots keep short, wide and tall module symbols on the same centerline.
/// The caller owns typography and color; this component has no monitoring effects.
struct GeekModuleIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        AppSymbolGlyph(systemImage: systemImage, size: MiniWindowStyleTokens.moduleIconGlyphSize)
            .foregroundStyle(tint)
            .frame(width: MiniWindowStyleTokens.moduleIconSlotSize,
                   height: MiniWindowStyleTokens.moduleIconSlotSize)
            .accessibilityHidden(true)
    }
}

struct GeekModuleLabel<Title: View>: View {
    let systemImage: String
    let tint: Color
    let title: Title

    init(systemImage: String, tint: Color, @ViewBuilder title: () -> Title) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title()
    }

    var body: some View {
        HStack(alignment: .center, spacing: MiniWindowStyleTokens.moduleIconSpacing) {
            GeekModuleIcon(systemImage: systemImage, tint: tint)
            title
        }
    }
}

/// The module title row used by overview cards and by the secondary pages
/// that open with one (CPU, Memory): the 12 pt panel-title font, the
/// section-header color for both icon and title, and an optional trailing
/// readout. Load or state colors belong to the readout, never to the heading.
struct GeekModuleHeader<Trailing: View>: View {
    @Environment(\.panelMetricColors) private var metricColors
    let systemImage: String
    let title: String
    let trailing: Trailing

    init(
        systemImage: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.systemImage = systemImage
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: MiniWindowStyleTokens.inlineSpacing) {
            GeekModuleLabel(systemImage: systemImage, tint: metricColors.sectionHeader) {
                Text(title).foregroundStyle(metricColors.sectionHeader)
            }
            .font(AdvancedPanelTypography.header)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: MiniWindowStyleTokens.inlineSpacing)
            trailing
        }
    }
}

extension GeekModuleHeader where Trailing == EmptyView {
    init(systemImage: String, title: String) {
        self.init(systemImage: systemImage, title: title) { EmptyView() }
    }
}

/// One rule for every titled group inside a mini-window card (进程, 频率,
/// 温度, 风扇, IP 地址 …): 11 pt semibold in the section-header color.
/// Load or pressure states color the data (rings, bars), never a heading.
struct GeekSectionTitle: View {
    @Environment(\.panelMetricColors) private var metricColors
    let title: String

    var body: some View {
        Text(title)
            .font(AdvancedPanelTypography.captionStrong)
            .foregroundStyle(metricColors.sectionHeader)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A value column label in a process table. A tint draws the same dot as
/// the page's legends; untinted columns show the label only.
struct GeekProcessListColumn: Identifiable {
    let id: String
    let title: String
    var tint: Color?
    var accessibilityLabel: String?
}

/// The single header style for every process table in the mini window:
/// section title, optional sampling status, optional controls, and value
/// column labels right-aligned on the value columns of the rows below.
///
/// Labels never truncate. With several columns each label keeps the row's
/// 60 pt value slot, so the columns stay aligned, and a label one point wider
/// (English "● Download") extends into the gap on its left. A single column
/// is the row's last item and only needs its label's width, which leaves the
/// rest of the row to the title (English "USING SIGNIFICANT ENERGY" beside
/// "Power" on the 232 pt power page).
struct GeekProcessListHeader<Accessory: View>: View {
    let title: String
    var status: String?
    var help: String?
    var columns: [GeekProcessListColumn]
    let accessory: Accessory

    init(
        title: String,
        status: String? = nil,
        help: String? = nil,
        columns: [GeekProcessListColumn] = [],
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.status = status
        self.help = help
        self.columns = columns
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: MiniWindowStyleTokens.inlineSpacing) {
            GeekSectionTitle(title: title)
                .layoutPriority(1)
                .help(help ?? "")
                .accessibilityValue(status ?? "")
                .processHeaderLayoutProbe("process-header.title")
            Spacer(minLength: MiniWindowStyleTokens.rowSpacing)
            if let status {
                Text(status)
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            accessory
            ForEach(columns) { column in
                columnLabel(column)
                    .frame(
                        width: columns.count > 1 ? GeekSecondaryTransferLayout.processValueColumnWidth : nil,
                        alignment: .trailing
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(column.accessibilityLabel ?? column.title)
            }
        }
        .frame(minHeight: GeekSecondaryTransferLayout.processRowHeight)
        .processHeaderLayoutProbe("process-header.row")
    }

    private func columnLabel(_ column: GeekProcessListColumn) -> some View {
        HStack(spacing: 3) {
            if let tint = column.tint {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(column.title)
                .lineLimit(1)
                .processHeaderLayoutProbe("process-header.column.\(column.id)")
        }
        .font(AdvancedPanelTypography.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

private extension View {
    @ViewBuilder
    func processHeaderLayoutProbe(_ id: String) -> some View {
        #if DEBUG
        layoutProbe(id)
        #else
        self
        #endif
    }
}

extension GeekProcessListHeader where Accessory == EmptyView {
    init(
        title: String,
        status: String? = nil,
        help: String? = nil,
        columns: [GeekProcessListColumn] = []
    ) {
        self.init(title: title, status: status, help: help, columns: columns) { EmptyView() }
    }
}

struct GeekDisclosureIcon: View {
    var systemImage = AppSymbols.Panel.disclosure

    var body: some View {
        AppSymbolGlyph(systemImage: systemImage, size: MiniWindowStyleTokens.disclosureGlyphSize,
                       weight: .semibold)
            .foregroundStyle(.tertiary)
            .frame(width: MiniWindowStyleTokens.disclosureIconSlotSize,
                   height: MiniWindowStyleTokens.disclosureIconSlotSize)
            .accessibilityHidden(true)
    }
}

/// Display in the actual row slot instead of shrinking a 24-point parent layout.
/// The existing bounded icon cache retains its own decoding resolution.
/// Context-specific symbols remain available when a process has no app icon.
struct GeekSecondaryProcessIcon: View {
    let path: String
    var fallback: String = "app.fill"

    var body: some View {
        CachedAppIconView(path: path, size: MiniWindowStyleTokens.processIconSize) {
            AppSymbolGlyph(systemImage: fallback, size: MiniWindowStyleTokens.processIconSize,
                           renderingMode: .hierarchical)
                .foregroundStyle(.secondary)
        }
        .frame(width: MiniWindowStyleTokens.processIconSize,
               height: MiniWindowStyleTokens.processIconSize)
        .accessibilityHidden(true)
    }
}

enum GeekPanelLayout {
    static let contentPadding = MiniWindowStyleTokens.contentInset
    static let sectionSpacing = MiniWindowStyleTokens.cardSpacing
    static let detailSpacing = MiniWindowStyleTokens.cardSpacing
    static let overviewProcessorCardHeight: CGFloat = 106
    static let overviewMemoryCardHeight: CGFloat = 122
    static let overviewDiskCardHeight: CGFloat = 78
    static let overviewNetworkCardHeight: CGFloat = 81
    static let overviewSensorsCardHeight: CGFloat = 108
    static let overviewPowerCardHeight: CGFloat = 64
    static let moduleMinimumWidth: CGFloat = 220
    static let metricMinimumHeight: CGFloat = 60
    static let primaryChartHeight: CGFloat = 64
    static let overviewChartHeight: CGFloat = 48
    // Use more of the existing CPU card for the fixed 0–100% plot. The shared
    // presentation keeps the header and legend close, without widening cards.
    static let overviewProcessorChartHeight: CGFloat = 60
    static let overviewNetworkChartHeight: CGFloat = 40

    static func overviewSize(showsPowerModule: Bool) -> CGSize {
        overviewSize(modules: [.processorGraphics, .coreMetrics, .disk, .network, .sensors]
            + (showsPowerModule ? [.power] : []))
    }

    static func overviewSize(modules: [GeekDashboardModule]) -> CGSize {
        let heights: [CGFloat] = modules.compactMap { module in
            switch module {
            case .processorGraphics: overviewProcessorCardHeight
            case .coreMetrics: overviewMemoryCardHeight
            case .disk: overviewDiskCardHeight
            case .network: overviewNetworkCardHeight
            case .sensors: overviewSensorsCardHeight
            case .power: overviewPowerCardHeight
            case .memoryBreakdown, .fans, .systemLoad, .cleanupSummary: nil
            }
        }
        return CGSize(
            width: MiniWindowStyleTokens.overviewSize.width,
            height: heights.reduce(0, +)
                + CGFloat(max(0, heights.count - 1)) * sectionSpacing
                + contentPadding * 2
        )
    }
}

enum GeekVisualTokens {
    static let cardRadius = MiniWindowStyleTokens.cardCornerRadius
    static let cardHorizontalPadding = MiniWindowStyleTokens.cardHorizontalInset
    static let cardVerticalPadding = MiniWindowStyleTokens.cardVerticalInset
    static let overviewMemoryGaugeSize: CGFloat = 88
    static let detailMemoryGaugeSize: CGFloat = 112

    static func ringTrack(for colorScheme: ColorScheme, visualMode: MiniWindowVisualMode) -> Color {
        if colorScheme == .light { return MonitorPalette.lightRingTrack }
        return visualMode == .black ? MonitorPalette.blackRingTrack : MonitorPalette.graphiteRingTrack
    }

    // The 068 reference uses a roughly six-percent track at the detail scale.
    // Keep small readouts legible without changing the track for different values.
    static func gaugeStrokeWidth(size: CGFloat) -> CGFloat {
        min(6, max(2, size * 0.0625))
    }

    static func cardFill(for colorScheme: ColorScheme, visualMode: MiniWindowVisualMode) -> Color {
        // Graphite keeps its inset. Black uses an opaque, neutral card so the
        // native backdrop cannot brighten or tint the card through the shell.
        colorScheme == .dark
            ? (visualMode == .black ? MonitorPalette.blackCard : MonitorPalette.graphiteCardOverlay)
            : AppAppearanceColors.panel
    }

    static func cardBorder(
        for colorScheme: ColorScheme,
        visualMode: MiniWindowVisualMode,
        isActive: Bool = false,
        isSelected: Bool = false
    ) -> Color {
        if isSelected {
            return AppAppearanceColors.controlAccent.opacity(0.82)
        }
        if isActive {
            return AppAppearanceColors.controlAccent.opacity(colorScheme == .dark ? 0.82 : 0.65)
        }
        return colorScheme == .dark
            ? Color.white.opacity(visualMode == .black ? 0.10 : 0.12)
            : AppAppearanceColors.border
    }

    static func cardBorderLineWidth(
        isActive: Bool,
        isSelected: Bool = false,
        displayScale: CGFloat
    ) -> CGFloat {
        MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
    }
}

struct GeekMetricCellModel: Identifiable {
    let id: String
    let tile: AdvancedMetricTileModel
    let destination: PanelSection?
}

struct GeekMetricGrid: View {
    let items: [GeekMetricCellModel]
    let onSelect: (PanelSection) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(columns: 3, minimumCellWidth: 136)
            grid(columns: 2, minimumCellWidth: 126)
            grid(columns: 1, minimumCellWidth: 220)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rows(columns: Int) -> [[GeekMetricCellModel]] {
        stride(from: 0, to: items.count, by: columns).map { start in
            Array(items[start..<min(items.count, start + columns)])
        }
    }

    private func grid(columns: Int, minimumCellWidth: CGFloat) -> some View {
        let rows = rows(columns: columns)
        return Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { item in
                        GeekMetricCell(
                            model: item.tile,
                            action: item.destination.map { destination in
                                { onSelect(destination) }
                            }
                        )
                        .frame(minWidth: minimumCellWidth, maxWidth: .infinity)
                    }

                }
            }
        }
    }
}

struct GeekMetricSummaryGrid: View {
    let tiles: [AdvancedMetricTileModel]

    var body: some View {
        GeekMetricGrid(
            items: tiles.map { tile in
                GeekMetricCellModel(
                    id: tile.id,
                    tile: tile,
                    destination: nil
                )
            },
            onSelect: { _ in }
        )
    }
}

/// The compact, single-column surface used by the Geek overview. Its fixed
/// module heights mirror the scan rhythm of a native menu-bar monitor while
/// the enclosing Panel remains the app's existing shared Panel scene.
private struct GeekCombinedCardUsesDividerKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var geekCombinedCardUsesDivider: Bool {
        get { self[GeekCombinedCardUsesDividerKey.self] }
        set { self[GeekCombinedCardUsesDividerKey.self] = newValue }
    }
}

/// Intrinsically sized control/history group, using the same border and insets
/// as the fixed-height overview cards. Content determines its height so an
/// expanded control, translated label or error message cannot cross its border.
struct MiniWindowGroup<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.miniWindowVisualMode) private var visualMode
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.displayScale) private var displayScale
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: MiniWindowStyleTokens.rowSpacing) {
            content
        }
        .font(AdvancedPanelTypography.body)
        .padding(.horizontal, GeekVisualTokens.cardHorizontalPadding)
        .padding(.vertical, GeekVisualTokens.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .geekCardSurface(colorScheme: colorScheme, visualMode: visualMode, displayScale: displayScale, palette: panelChromePalette)
    }
}

struct GeekCombinedCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.miniWindowVisualMode) private var visualMode
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.displayScale) private var displayScale
    @Environment(\.geekCombinedCardUsesDivider) private var usesDivider
    @Environment(\.geekCombinedCardIsActive) private var isActive
    @Environment(\.geekCombinedCardIsSelected) private var isSelected

    let height: CGFloat
    let content: Content

    init(
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.height = height
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, GeekVisualTokens.cardHorizontalPadding)
            .padding(.vertical, GeekVisualTokens.cardVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            .background {
                if !usesDivider {
                    Color.clear.geekCardSurface(colorScheme: colorScheme, visualMode: visualMode, displayScale: displayScale, palette: panelChromePalette, isActive: isActive, isSelected: isSelected)
                } else if isActive || isSelected {
                    RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius)
                        .fill(panelChromePalette?.selection ?? Color.accentColor.opacity(0.10))
                }
            }
            .overlay(alignment: .bottom) {
                if usesDivider {
                    Divider().padding(.horizontal, GeekVisualTokens.cardHorizontalPadding)
                }
            }
    }
}

private extension View {
    func geekCardSurface(
        colorScheme: ColorScheme,
        visualMode: MiniWindowVisualMode,
        displayScale: CGFloat,
        palette: PanelChromePalette? = nil,
        isActive: Bool = false,
        isSelected: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: GeekVisualTokens.cardRadius,
            style: .continuous
        )
        let fill = palette.map { isActive || isSelected ? $0.selection : $0.card }
            ?? GeekVisualTokens.cardFill(for: colorScheme, visualMode: visualMode)
        return background(shape.fill(fill))
            .overlay {
                shape
                    .strokeBorder(
                        palette.map { isActive || isSelected ? $0.accent : $0.border } ?? GeekVisualTokens.cardBorder(
                            for: colorScheme,
                            visualMode: visualMode,
                            isActive: isActive,
                            isSelected: isSelected
                        ),
                        lineWidth: GeekVisualTokens.cardBorderLineWidth(
                            isActive: isActive,
                            isSelected: isSelected,
                            displayScale: displayScale
                        )
                    )
                    .allowsHitTesting(false)
            }
    }
}


enum GeekCombinedRingLabelPlacement {
    case aboveValue
    case belowValue
}

struct GeekCombinedRingSegment: Identifiable {
    let id: String
    let progress: Double
    let color: Color
}

private struct GeekCombinedRingSpan: Identifiable {
    let id: String
    let lowerBound: Double
    let upperBound: Double
    let color: Color
}

/// A small, bounded text-layout cache. Native font metrics decide whether a
/// label needs a second line; live numeric updates do not repeat that work.
@MainActor
struct GeekRingLabelMetrics {
    let lineCount: Int
    let height: CGFloat
    let fontSize: CGFloat

    private struct Key: Hashable {
        let text: String
        let fontSize: CGFloat
        let width: CGFloat
    }
    private static var cache: [Key: GeekRingLabelMetrics] = [:]
    private static var insertionOrder: [Key] = []
    private static let capacity = 32

    static func measure(text: String, fontSize: CGFloat, width: CGFloat) -> GeekRingLabelMetrics {
        guard !text.isEmpty, fontSize > 0, width > 0 else {
            return GeekRingLabelMetrics(lineCount: 0, height: 0, fontSize: fontSize)
        }
        let key = Key(text: text, fontSize: fontSize, width: width)
        if let cached = cache[key] { return cached }
        let preferredFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let singleLineWidth = (text as NSString).size(withAttributes: [.font: preferredFont]).width
        let lineCount = singleLineWidth <= width && !text.contains("\n") ? 1 : 2
        let longestWordWidth = text.split(whereSeparator: { $0.isWhitespace })
            .map { (String($0) as NSString).size(withAttributes: [.font: preferredFont]).width }
            .max() ?? singleLineWidth
        // In the 88 pt overview, PRESSURE is 52.39 pt at 10 pt while the
        // safe inner square is 51.62 pt. A fixed 9 pt floor keeps the word
        // intact without widening the readout beyond that safe square.
        let fittedFontSize = lineCount > 1 && longestWordWidth > width
            ? max(9, fontSize - 1) : fontSize
        let font = NSFont.systemFont(ofSize: fittedFontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        let measured = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // NSString includes the rounded native line box. NSLayoutManager's
        // default line height omits one point here (13 versus SwiftUI's 14
        // at 11 pt), so multiplying it under-budgets two-line labels.
        let lineHeight = ("Ag" as NSString).size(withAttributes: [.font: font]).height
        let result = GeekRingLabelMetrics(
            lineCount: lineCount,
            height: ceil(max(measured.height, lineHeight * CGFloat(lineCount))),
            fontSize: fittedFontSize
        )
        if insertionOrder.count == capacity {
            cache.removeValue(forKey: insertionOrder.removeFirst())
        }
        cache[key] = result
        insertionOrder.append(key)
        return result
    }
}

/// The same native Text is used in the ring and in rendering regressions.
/// Long labels wrap at their regular font size instead of ellipsizing or
/// shrinking indefinitely. Short CPU/GPU labels retain their existing style.
struct GeekCombinedRingLabel: View {
    let text: String
    let fontSize: CGFloat
    let width: CGFloat

    var body: some View {
        let uppercased = text.uppercased()
        let metrics = GeekRingLabelMetrics.measure(text: uppercased, fontSize: fontSize, width: width)
        let words = uppercased.split(whereSeparator: { $0.isWhitespace })
        // Keep the two whole words on separate native lines. The automatic
        // wrap retains trailing-space layout, unlike an explicit word break,
        // and can shift a centered word by a fractional pixel.
        let displayedText = metrics.lineCount == 2 && words.count == 2
            ? words.joined(separator: "\n") : uppercased
        Text(displayedText)
            .font(.system(size: metrics.fontSize, weight: .regular))
            .foregroundStyle(.primary.opacity(0.77))
            .multilineTextAlignment(.center)
            .lineLimit(metrics.lineCount)
            .allowsTightening(true)
            .minimumScaleFactor(metrics.lineCount > 1 ? 1 : 0.75)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width)
    }
}

/// A compact circular readout with all explanatory text inside the ring.
/// A missing percentage keeps a neutral track and never invents a fan limit.
struct GeekCombinedRing: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.miniWindowVisualMode) private var visualMode
    let title: String
    let value: String
    var detail: String? = nil
    var statusSymbol: String? = nil
    var statusSymbolTint: Color? = nil
    let progress: Double?
    let tint: Color
    let size: CGFloat
    var labelPlacement: GeekCombinedRingLabelPlacement = .belowValue
    var segments: [GeekCombinedRingSegment] = []
    var fixedValueFontSize: CGFloat? = nil
    var detailLineLimit = 1
    var fixedDetailFontSize: CGFloat? = nil
    var strokeWidth: CGFloat? = nil
    /// A discrete state colors the whole track; it does not imply a percentage.
    var isStatusOnly = false
    /// Full name for VoiceOver when `title` is a ring-sized abbreviation.
    var accessibilityTitle: String? = nil

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(isStatusOnly ? tint : GeekVisualTokens.ringTrack(for: colorScheme, visualMode: visualMode),
                        lineWidth: lineWidth)

            if !normalizedSegmentSpans.isEmpty {
                ForEach(normalizedSegmentSpans) { segment in
                    Circle()
                        .inset(by: lineWidth / 2)
                        .trim(from: segment.lowerBound, to: segment.upperBound)
                        .stroke(
                            segment.color,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                        )
                        .rotationEffect(.degrees(-90))
                }
            } else if let normalizedProgress {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: normalizedProgress)
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: size < 40 ? 0 : -1) {
                if let statusSymbol {
                    Image(systemName: statusSymbol)
                        .font(.system(size: size < 40 ? 8 : 11, weight: .semibold))
                        .foregroundStyle(statusSymbolTint ?? tint)
                        .frame(height: size < 40 ? 9 : 12)
                        .accessibilityHidden(true)
                }

                if labelFontSize > 0, labelPlacement == .aboveValue, !title.isEmpty {
                    ringLabel(title)
                }

                ringValue

                if labelFontSize > 0, labelPlacement == .belowValue, !title.isEmpty {
                    ringLabel(title)
                }

                if detailFontSize > 0, let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: fixedDetailFontSize ?? detailFontSize, weight: .regular))
                        .foregroundStyle(.primary.opacity(0.77))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .lineLimit(detailLineLimit)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: contentBoxSide)
                }
            }
            .frame(width: contentBoxSide, height: contentBoxSide)
            .clipped()
        }
        .frame(width: size, height: size)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityValue(displayValue)
        .accessibilityHint(detail ?? "")
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var normalizedProgress: Double? {
        guard let progress, progress.isFinite else { return nil }
        return min(1, max(0, progress))
    }

    private var normalizedSegmentSpans: [GeekCombinedRingSpan] {
        var cursor = 0.0
        return segments.compactMap { segment in
            guard segment.progress.isFinite, segment.progress > 0, cursor < 1 else {
                return nil
            }
            let lowerBound = cursor
            let upperBound = min(1, cursor + segment.progress)
            cursor = upperBound
            return GeekCombinedRingSpan(
                id: segment.id,
                lowerBound: lowerBound,
                upperBound: upperBound,
                color: segment.color
            )
        }
    }

    private var hasConcreteValue: Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "--" && trimmed != "—" && !trimmed.contains("--")
    }

    private var displayValue: String { hasConcreteValue ? value : "—" }
    private var lineWidth: CGFloat { strokeWidth ?? GeekVisualTokens.gaugeStrokeWidth(size: size) }
    private var contentDiameter: CGFloat {
        Self.contentDiameter(size: size, lineWidth: lineWidth)
    }

    nonisolated static func contentDiameter(size: CGFloat, lineWidth: CGFloat) -> CGFloat {
        max(12, size - (lineWidth + 2) * 2)
    }

    private var contentBoxSide: CGFloat { contentDiameter / sqrt(2) }

    var valueFontSize: CGFloat {
        let preferred: CGFloat = fixedValueFontSize ?? (size >= 90 ? 28 : size >= 68 ? 15 : size >= 52 ? 13 : 10)
        let readout = Self.splitReadout(displayValue)
        let number = readout?.number ?? displayValue
        let unitWidth = CGFloat(readout?.unit.count ?? 0) * 0.62 * 0.65
        let widthBudget = contentBoxSide / max(1, CGFloat(number.count) * 0.65 + unitWidth)
        let labelMetrics = GeekRingLabelMetrics.measure(
            text: title.uppercased(), fontSize: labelFontSize, width: contentBoxSide
        )
        let detailRows = detailFontSize > 0 && detail?.isEmpty == false ? detailLineLimit : 0
        let reservedTextHeight: CGFloat
        if labelMetrics.lineCount > 1 {
            reservedTextHeight = labelMetrics.height
                + CGFloat(detailRows) * max(labelFontSize, detailFontSize) * 1.2
        } else {
            // Preserve the existing numeric size for a one-line label.
            reservedTextHeight = CGFloat(labelMetrics.lineCount + detailRows)
                * max(labelFontSize, detailFontSize) * 1.2
        }
        let heightBudget = (contentBoxSide - reservedTextHeight
                            - (statusSymbol == nil ? 0 : 12)) / 1.2
        return max(8, min(preferred, widthBudget, heightBudget))
    }

    nonisolated static func splitReadout(_ value: String) -> (number: String, unit: String)? {
        let characters = value.prefix { $0.isNumber || ".,-+−".contains($0) }
        guard characters.contains(where: { $0.isNumber }) else { return nil }
        return (String(characters), String(value.dropFirst(characters.count)).trimmingCharacters(in: .whitespaces))
    }

    var labelFontSize: CGFloat {
        if size >= 90 { return 11 }
        if size >= 68 { return 10 }
        if size >= 52 { return 9 }
        return 0
    }

    var detailFontSize: CGFloat {
        if size >= 90 { return 11 }
        if size >= 68 { return 10 }
        if size >= 52 { return 8.5 }
        return 0
    }

    private var ringValue: some View {
        let readout = Self.splitReadout(displayValue)
        return (Text(readout?.number ?? displayValue).font(.system(size: valueFontSize, weight: .regular))
                + Text(readout?.unit ?? "").font(.system(size: valueFontSize * 0.62, weight: .regular)))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: contentBoxSide)
    }

    @ViewBuilder
    private func ringLabel(_ text: String) -> some View {
        GeekCombinedRingLabel(text: text, fontSize: labelFontSize, width: contentBoxSide)
    }

    private var helpText: String {
        guard let detail else { return "\(title): \(displayValue)" }
        return "\(title): \(displayValue) · \(detail)"
    }
}

struct GeekCombinedLegendMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)

            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.primary)

            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct GeekPanelHoverCoordinatorKey: EnvironmentKey {
    static let defaultValue: GeekPanelCoordinator? = nil
}

private struct GeekCombinedCardActiveKey: EnvironmentKey {
    static let defaultValue = false
}

private struct GeekCombinedCardSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var geekPanelHoverCoordinator: GeekPanelCoordinator? {
        get { self[GeekPanelHoverCoordinatorKey.self] }
        set { self[GeekPanelHoverCoordinatorKey.self] = newValue }
    }

    var geekCombinedCardIsActive: Bool {
        get { self[GeekCombinedCardActiveKey.self] }
        set { self[GeekCombinedCardActiveKey.self] = newValue }
    }

    var geekCombinedCardIsSelected: Bool {
        get { self[GeekCombinedCardSelectedKey.self] }
        set { self[GeekCombinedCardSelectedKey.self] = newValue }
    }
}

/// Where a level-one card's anchor is measured from.
enum GeekOverviewAnchorPlacement: Equatable {
    /// The window shows only the overview: the card's native screen frame is
    /// measured in the same window the session places.
    case overviewOnly
    /// The overview is one column of the attached cascade. The anchor is the
    /// card's layout frame inside the overview, placed on the overview frame
    /// of the session's cascade; nil until that layout reaches the view.
    case attached(overviewScreenFrame: NSRect?)
}

/// Coordinate space of the overview page; its origin is the overview shell's
/// top-left corner in both the overview-only and the attached presentation.
enum GeekOverviewAnchorSpace {
    static let name = "geek.overview.anchor-space"
}

enum GeekModuleAnchorGeometry {
    /// A card's screen rect from its frame in `GeekOverviewAnchorSpace`
    /// (top-left origin, y down) and the overview's screen frame (y up).
    static func screenRect(layoutFrame: CGRect, overviewScreenFrame: NSRect) -> NSRect {
        NSRect(
            x: overviewScreenFrame.minX + layoutFrame.minX,
            y: overviewScreenFrame.maxY - layoutFrame.maxY,
            width: layoutFrame.width,
            height: layoutFrame.height
        )
    }
}

private struct GeekOverviewAnchorPlacementKey: EnvironmentKey {
    static let defaultValue = GeekOverviewAnchorPlacement.overviewOnly
}

extension EnvironmentValues {
    var geekOverviewAnchorPlacement: GeekOverviewAnchorPlacement {
        get { self[GeekOverviewAnchorPlacementKey.self] }
        set { self[GeekOverviewAnchorPlacementKey.self] = newValue }
    }
}

/// Registers a level-one card as the anchor its secondary page opens against:
/// the secondary's top edge is the card's top edge.
///
/// The native reader reports when it is attached to a window or resized, but
/// not when the card only moves. Opening a section recreates the overview
/// cards inside the attached shell, which first lays the overview out at its
/// default frame (bottom-aligned when the detail is taller than the overview,
/// as the CPU page is) until the cascade layout arrives. When the new card
/// reported in that frame, the registry kept the transient position and the
/// CPU secondary opened below its card (38.5 pt in the batch 2b capture).
///
/// In the attached cascade the anchor is therefore derived from the card's
/// layout frame and the cascade's overview frame, which is the frame the
/// session measures from, so a window frame and a SwiftUI layout that are
/// applied at different moments cannot disagree. With the overview alone in
/// the window the native frame is used, re-read whenever the card moves.
struct GeekModuleAnchorRegistration: ViewModifier {
    @Environment(\.geekPanelHoverCoordinator) private var hoverCoordinator
    @Environment(\.geekOverviewAnchorPlacement) private var placement
    let destination: PanelSection
    let handle: SmallWindowAnchorHandle

    private struct Trigger: Equatable {
        let windowFrame: CGRect
        let layoutFrame: CGRect
        let placement: GeekOverviewAnchorPlacement
    }

    func body(content: Content) -> some View {
        let coordinator = hoverCoordinator
        let destination = destination
        let handle = handle
        let placement = placement
        content
            .background {
                SmallWindowAnchorReader(
                    handle: handle,
                    onSnapshotChanged: { rect, _ in
                        // An attached card registers its layout frame below.
                        guard placement == .overviewOnly else { return }
                        coordinator?.registerAnchor(
                            id: .module(destination),
                            screenRect: rect,
                            contentKind: destination.rawValue
                        )
                    }
                )
            }
            .background {
                GeometryReader { proxy in
                    let trigger = Trigger(
                        windowFrame: proxy.frame(in: .global),
                        layoutFrame: proxy.frame(in: .named(GeekOverviewAnchorSpace.name)),
                        placement: placement
                    )
                    Color.clear
                        .onChange(of: trigger, initial: true) {
                            Self.publish(
                                destination,
                                layoutFrame: trigger.layoutFrame,
                                placement: trigger.placement,
                                handle: handle,
                                coordinator: coordinator
                            )
                        }
                }
            }
    }

    /// Registers on the next main-queue turn: the session reacts to a new
    /// anchor by placing the cascade, which must not happen inside a view
    /// update, and a native frame is read after AppKit applied the move.
    @MainActor
    private static func publish(
        _ destination: PanelSection,
        layoutFrame: CGRect,
        placement: GeekOverviewAnchorPlacement,
        handle: SmallWindowAnchorHandle,
        coordinator: GeekPanelCoordinator?
    ) {
        guard let coordinator else { return }
        DispatchQueue.main.async {
            let rect: NSRect
            switch placement {
            case .overviewOnly:
                guard let snapshot = handle.snapshot() else { return }
                rect = snapshot.rect
            case let .attached(overviewScreenFrame?):
                rect = GeekModuleAnchorGeometry.screenRect(
                    layoutFrame: layoutFrame,
                    overviewScreenFrame: overviewScreenFrame
                )
            case .attached(overviewScreenFrame: nil):
                // Keep the overview-only registration until the cascade
                // layout arrives; the default frame is not on screen yet.
                return
            }
            // The card's top offset inside the overview places the secondary
            // page whatever frame the window has at this moment.
            coordinator.registerAnchor(
                id: .module(destination),
                screenRect: rect,
                contentKind: destination.rawValue,
                layoutOffset: layoutFrame.minY
            )
        }
    }
}

struct GeekOverviewModuleButton<Content: View>: View {
    @Environment(\.geekPanelHoverCoordinator) private var hoverCoordinator

    let destination: PanelSection
    let isSelected: Bool
    let accessibilityLabel: String?
    let preview: (PanelSection) -> Void
    let action: (PanelSection) -> Void
    let content: Content

    @State private var isHovering = false
    @State private var previewHoverIntent: GeekPanelCoordinator.HoverIntent?
    @State private var anchorHandle = SmallWindowAnchorHandle()

    init(
        destination: PanelSection,
        isSelected: Bool = false,
        accessibilityLabel: String? = nil,
        preview: @escaping (PanelSection) -> Void = { _ in },
        action: @escaping (PanelSection) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.destination = destination
        self.isSelected = isSelected
        self.accessibilityLabel = accessibilityLabel
        self.preview = preview
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button {
            action(destination)
        } label: {
            content
                .environment(\.geekCombinedCardIsActive, isHovering)
                .environment(\.geekCombinedCardIsSelected, isSelected)
                .modifier(GeekModuleAnchorRegistration(destination: destination, handle: anchorHandle))
        }
        .appButtonChrome(.metric)
        .contentShape(RoundedRectangle(
            cornerRadius: GeekVisualTokens.cardRadius,
            style: .continuous
        ))
        .onContinuousHover { phase in
            switch phase {
            case .active:
                updateHover(true)
            case .ended:
                updateHover(false)
            }
        }
        .onDisappear {
            updateHover(false)
            hoverCoordinator?.removeAnchor(.module(destination))
        }
        .accessibilityLabel(accessibilityLabel ?? destination.title)
        .accessibilityHint(L10n.text("打开二级监控详情", "Open secondary monitoring details"))
    }

    private func updateHover(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        if let previewHoverIntent {
            hoverCoordinator?.invalidateHoverIntent(previewHoverIntent)
            self.previewHoverIntent = nil
        }
        if !hovering {
            hoverCoordinator?.moduleHoverExited(destination)
            return
        }
        guard hovering, !isSelected else { return }
        guard let hoverCoordinator else {
            preview(destination)
            return
        }
        let hoverIntent = hoverCoordinator.scheduleModulePreview(
            destination,
            condition: { isHovering && !isSelected },
            action: { preview(destination) }
        )
        previewHoverIntent = hoverIntent
    }
}

struct GeekOverviewHoverRegion<Content: View>: View {
    @Environment(\.geekPanelHoverCoordinator) private var hoverCoordinator

    let destination: PanelSection
    let isSelected: Bool
    let preview: (PanelSection) -> Void
    let content: Content

    @State private var isHovering = false
    @State private var hoverIntent: GeekPanelCoordinator.HoverIntent?
    @State private var anchorHandle = SmallWindowAnchorHandle()

    init(
        destination: PanelSection,
        isSelected: Bool = false,
        preview: @escaping (PanelSection) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.destination = destination
        self.isSelected = isSelected
        self.preview = preview
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.geekCombinedCardIsActive, isHovering)
            .modifier(GeekModuleAnchorRegistration(destination: destination, handle: anchorHandle))
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    updateHover(true)
                case .ended:
                    updateHover(false)
                }
            }
            .onDisappear {
                updateHover(false)
                hoverCoordinator?.removeAnchor(.module(destination))
            }
    }

    private func updateHover(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        if let hoverIntent {
            hoverCoordinator?.invalidateHoverIntent(hoverIntent)
            self.hoverIntent = nil
        }
        if !hovering {
            hoverCoordinator?.moduleHoverExited(destination)
            return
        }
        guard hovering, !isSelected, let hoverCoordinator else { return }
        hoverIntent = hoverCoordinator.scheduleModulePreview(
            destination,
            condition: { isHovering && !isSelected },
            action: { preview(destination) }
        )
    }
}

struct GeekMetricCell: View {
    let model: AdvancedMetricTileModel
    let action: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    content
                }
                .appButtonChrome(.metric)
                .accessibilityHint(L10n.text("打开对应监控页面", "Open the related monitor page"))
            } else {
                content
            }
        }
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(
                cornerRadius: AppDesignTokens.Layout.rowRadius,
                style: .continuous
            )
            .fill(isHovering ? Color.primary.opacity(0.045) : Color.clear)
        }
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.title)
        .accessibilityValue(model.value)
        .accessibilityHint(model.detail)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var content: some View {
        Group {
            if model.progress != nil {
                PanelCircularGauge(
                    title: model.title,
                    value: model.value,
                    progress: model.progress,
                    tint: model.tint,
                    detail: nil,
                    size: 50
                )
            } else {
                VStack(spacing: 2) {
                    Text(model.title.uppercased())
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(displayValue)
                        .font(AdvancedPanelTypography.compactValue)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)

                    Text(displayDetail)
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .frame(
            maxWidth: .infinity,
            minHeight: GeekPanelLayout.metricMinimumHeight,
            alignment: .center
        )
    }

    private var hasConcreteValue: Bool {
        let value = model.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != "--" && value != "—" && !value.contains("--")
    }

    private var displayValue: String {
        hasConcreteValue ? model.value : "—"
    }

    private var displayDetail: String {
        hasConcreteValue ? model.detail : L10n.text("不可用", "Unavailable")
    }

    private var helpText: String {
        "\(model.title): \(model.value) · \(model.detail)"
    }
}

struct GeekResponsiveColumns<Primary: View, Secondary: View>: View {
    private let spacing: CGFloat
    private let minimumColumnWidth: CGFloat
    private let primary: Primary
    private let secondary: Secondary

    init(
        spacing: CGFloat = GeekPanelLayout.sectionSpacing,
        minimumColumnWidth: CGFloat = GeekPanelLayout.moduleMinimumWidth,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary
    ) {
        self.spacing = spacing
        self.minimumColumnWidth = minimumColumnWidth
        self.primary = primary()
        self.secondary = secondary()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: spacing) {
                primary
                    .frame(minWidth: minimumColumnWidth, maxWidth: .infinity, alignment: .top)
                secondary
                    .frame(minWidth: minimumColumnWidth, maxWidth: .infinity, alignment: .top)
            }

            VStack(spacing: spacing) {
                primary
                    .frame(maxWidth: .infinity, alignment: .top)
                secondary
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
