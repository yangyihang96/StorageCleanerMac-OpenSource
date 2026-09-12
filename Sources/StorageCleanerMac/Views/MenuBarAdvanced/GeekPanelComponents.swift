import SwiftUI

enum GeekPanelLayout {
    static let contentPadding = MiniWindowStyleTokens.contentInset
    static let sectionSpacing = MiniWindowStyleTokens.cardSpacing
    static let detailSpacing = MiniWindowStyleTokens.cardSpacing
    static let overviewProcessorCardHeight: CGFloat = 94
    static let overviewMemoryCardHeight: CGFloat = 102
    static let overviewDiskCardHeight: CGFloat = 78
    static let overviewNetworkCardHeight: CGFloat = 81
    static let overviewSensorsCardHeight: CGFloat = 108
    static let overviewPowerCardHeight: CGFloat = 60
    static let moduleMinimumWidth: CGFloat = 220
    static let metricMinimumHeight: CGFloat = 60
    static let primaryChartHeight: CGFloat = 64
    static let overviewChartHeight: CGFloat = 48
    static let overviewProcessorChartHeight: CGFloat = 39
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
    static let cardHorizontalPadding: CGFloat = 8
    static let cardVerticalPadding: CGFloat = 6
    static let overviewMemoryGaugeSize: CGFloat = 64
    static let detailMemoryGaugeSize: CGFloat = 104

    // The 068 reference uses a roughly six-percent track at the detail scale.
    // Keep small readouts legible without changing the track for different values.
    static func gaugeStrokeWidth(size: CGFloat) -> CGFloat {
        min(6, max(2, size * 0.0625))
    }

    static func cardFill(for colorScheme: ColorScheme) -> Color {
        // Let every card inherit the continuous shell and the user's tint.
        // An opaque, separately tinted card splits the panel into six surfaces.
        colorScheme == .dark
            ? Color.white.opacity(0.025)
            : Color.primary.opacity(0.025)
    }

    static func cardBorder(
        for colorScheme: ColorScheme,
        isActive: Bool = false,
        isSelected: Bool = false
    ) -> Color {
        if isSelected {
            return Color.accentColor.opacity(0.82)
        }
        if isActive {
            return Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.18)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.13)
            : Color.black.opacity(0.12)
    }

    static func cardBorderLineWidth(
        isActive: Bool,
        isSelected: Bool = false,
        displayScale: CGFloat
    ) -> CGFloat {
        isActive || isSelected
            ? 1
            : MiniWindowPixel.onePhysicalPixel(displayScale: displayScale)
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

struct GeekCombinedCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.geekCombinedCardUsesDivider) private var usesDivider
    @Environment(\.geekCombinedCardIsActive) private var isActive
    @Environment(\.geekCombinedCardIsSelected) private var isSelected

    let height: CGFloat
    let verticalPadding: CGFloat
    let content: Content

    init(
        height: CGFloat,
        verticalPadding: CGFloat = GeekVisualTokens.cardVerticalPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.height = height
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, GeekVisualTokens.cardHorizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background {
                if !usesDivider {
                    Color.clear.geekCardSurface(colorScheme: colorScheme, displayScale: displayScale, isActive: isActive, isSelected: isSelected)
                } else if isActive || isSelected {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.10))
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
        displayScale: CGFloat,
        isActive: Bool = false,
        isSelected: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: GeekVisualTokens.cardRadius,
            style: .continuous
        )
        return background(shape.fill(GeekVisualTokens.cardFill(for: colorScheme)))
            .overlay {
                shape
                    .strokeBorder(
                        GeekVisualTokens.cardBorder(
                            for: colorScheme,
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

/// A compact circular readout with all explanatory text inside the ring.
/// A missing percentage keeps a neutral track and never invents a fan limit.
struct GeekCombinedRing: View {
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

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(isStatusOnly ? tint : Color.secondary.opacity(0.32), lineWidth: lineWidth)

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
                        .minimumScaleFactor(0.72)
                }
            }
            .frame(width: contentDiameter, height: contentDiameter)
        }
        .frame(width: size, height: size)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
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

    private var valueFontSize: CGFloat {
        if let fixedValueFontSize { return fixedValueFontSize }
        if size >= 90 { return 28 }
        if size >= 68 { return 15 }
        if size >= 52 { return 13 }
        return 10
    }

    private var labelFontSize: CGFloat {
        if size >= 90 { return 11 }
        if size >= 68 { return 10 }
        if size >= 52 { return 9 }
        return 0
    }

    private var detailFontSize: CGFloat {
        if size >= 90 { return 11 }
        if size >= 68 { return 10 }
        if size >= 52 { return 8.5 }
        return 0
    }

    @ViewBuilder
    private var ringValue: some View {
        if fixedValueFontSize != nil {
            Text(displayValue)
                .font(.system(size: valueFontSize, weight: .regular))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: true)
        } else if size >= 90, let percentNumber {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(percentNumber)
                    .font(.system(size: valueFontSize, weight: .regular))
                Text("%")
                    .font(.system(size: 18, weight: .regular))
            }
            .foregroundStyle(.primary)
            .monospacedDigit()
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.72)
        } else {
            Text(displayValue)
                .font(.system(size: valueFontSize, weight: .regular))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.72)
        }
    }

    private var percentNumber: String? {
        guard displayValue.hasSuffix("%") else { return nil }
        return String(displayValue.dropLast())
    }

    @ViewBuilder
    private func ringLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: labelFontSize, weight: .regular))
            .foregroundStyle(.primary.opacity(0.77))
            .lineLimit(1)
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
                .background {
                    SmallWindowAnchorReader(
                        handle: anchorHandle,
                        onSnapshotChanged: { rect, _ in
                            hoverCoordinator?.registerAnchor(
                                id: .module(destination),
                                screenRect: rect,
                                contentKind: destination.rawValue
                            )
                        }
                    )
                }
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
            .background {
                SmallWindowAnchorReader(
                    handle: anchorHandle,
                    onSnapshotChanged: { rect, _ in
                        hoverCoordinator?.registerAnchor(
                            id: .module(destination),
                            screenRect: rect,
                            contentKind: destination.rawValue
                        )
                    }
                )
            }
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

struct GeekSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        tint _: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
                    .foregroundStyle(.primary)
            } icon: {
                AppSymbolIcon(
                    systemImage: systemImage,
                    role: .inline,
                    tint: AppDesignTokens.Palette.secondaryText,
                    isDecorative: true
                )
            }
            .font(AppPanelTypography.section)
            .accessibilityAddTraits(.isHeader)

            content
        }
        .padding(.horizontal, GeekVisualTokens.cardHorizontalPadding)
        .padding(.vertical, GeekVisualTokens.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .geekCardSurface(colorScheme: colorScheme, displayScale: displayScale)
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
