import SwiftUI

private extension FeatureLightfieldStatus {
    var pressureName: String {
        switch self {
        case .normal: L10n.text("正常", "Normal")
        case .warning: L10n.text("警告", "Warning")
        case .failure: L10n.text("紧张", "Critical")
        case .unknown: L10n.text("未提供", "Unavailable")
        }
    }
}

/// An extra line drawn over the primary samples (e.g. GPU beside CPU). Its
/// samples share the primary's x positions by index.
struct LightfieldTrendSeries: Identifiable, Equatable {
    let id: String
    let name: String
    let color: Color
    let samples: [LightfieldTrendSample]
}
enum LightfieldTrendAxis: Equatable, Sendable {
    /// "100% / 50% / 0" (approved memory trend).
    case percent
    /// No Y labels; the plot starts at the leading edge (approved run monitor).
    case hidden
    case labels(top: String, middle: String, bottom: String)
}
enum LightfieldTrendLegend: Equatable, Sendable {
    case none
    /// 12×2 line swatch + name per line (approved performance run: CPU / GPU).
    case series
    /// "● 正常 ● 警告 ● 紧张" in the status colours (approved memory landing).
    case pressure
}
struct LightfieldTrendHoverStyle: OptionSet, Sendable {
    let rawValue: Int
    /// Floating bubble at the cursor (approved memory-landing): time + value.
    static let bubble = Self(rawValue: 1)
    /// The earlier one-line readout above the plot.
    static let topLine = Self(rawValue: 2)
}

struct LightfieldTrendChart: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let samples: [LightfieldTrendSample]
    let module: ReviewFilter
    /// Approved memory trend: 96 pt plot, 42 pt axis column, 62 pt gutter for
    /// the current value label beside the last sample.
    var height: CGFloat = 96
    var hint: String? = nil
    // B2 review round: all additive with defaults that keep the memory usage.
    var title: String? = nil
    var primaryName: String? = nil
    var primaryColor: Color? = nil
    var series: [LightfieldTrendSeries] = []
    var legend: LightfieldTrendLegend = .none
    var showsPressureBands = true
    var axis: LightfieldTrendAxis = .percent
    var fillsArea = true
    var showsCurrentValue = true
    var valueFormat: LightfieldTrendValueFormat = .percent
    var hoverStyle: LightfieldTrendHoverStyle = .bubble
    var onHoverIndex: (Int?) -> Void = { _ in }
    var onSelection: (LightfieldTrendSelection?) -> Void = { _ in }
    /// Optional normalized x coordinates (power curves), never an index-as-watts scale.
    var xFractions: [Double]? = nil
    var xAxisLabels: (String, String)? = nil
    var xValueFormat: LightfieldTrendValueFormat? = nil
    var secondaryAxis: LightfieldTrendAxis? = nil
    var secondaryValueFormat: LightfieldTrendValueFormat? = nil
    var showsPoints = false
    var pointLabels: [String] = []
    var probeID = "lightfield.trend"
    /// Anchored to timestamps, not indices: live refreshes keep the moment.
    @State private var hoveredTime: Date?
    @State private var selectedTimes: ClosedRange<Date>?
    private var hoveredIndex: Int? { LightfieldChartGeometry.anchoredIndex(time: hoveredTime, in: samples) }
    private var selection: LightfieldTrendSelection? { LightfieldChartGeometry.anchoredSelection(times: selectedTimes, in: samples) }
    private var lineColor: Color { primaryColor ?? FeatureLightfieldPalette.accent(module) }
    private var axisWidth: CGFloat { axis == .hidden ? 0 : 42 }
    private var gutterWidth: CGFloat { showsCurrentValue ? 62 : 0 }
    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        VStack(alignment: .leading, spacing: 4) {
            if title != nil || legend != .none {
                header(palette).padding(.bottom, 12)
            }
            HStack(spacing: 0) {
                if axis != .hidden {
                    VStack(alignment: .trailing) {
                        axisText(axisLabels.0, id: "top"); Spacer(minLength: 0)
                        axisText(axisLabels.1, id: "middle"); Spacer(minLength: 0)
                        axisText(axisLabels.2, id: "bottom")
                    }.foregroundStyle(palette.fg2).frame(width: 36, alignment: .trailing).padding(.trailing, 6)
                    .lightfieldComponentProbe("lightfield.trend.axis")
                }
                GeometryReader { proxy in
                    plot(size: proxy.size, palette: palette)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point): setHover(LightfieldChartGeometry.index(at: point.x, width: proxy.size.width, count: samples.count, xFractions: xFractions))
                            case .ended: setHover(nil)
                            }
                        }
                        .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                            guard let current = LightfieldChartGeometry.index(at: event.location.x, width: proxy.size.width, count: samples.count, xFractions: xFractions) else { return }
                            setHover(current)
                            // Below the drag threshold this is a click: no one-sample range.
                            guard LightfieldChartGeometry.dragSelection(startX: event.startLocation.x,
                                    currentX: event.location.x, width: proxy.size.width, samples: samples, xFractions: xFractions) != nil,
                                  let start = LightfieldChartGeometry.index(at: event.startLocation.x, width: proxy.size.width, count: samples.count, xFractions: xFractions),
                                  let candidate = LightfieldChartGeometry.selection(start: start, end: current, samples: samples) else { return }
                            setSelection(candidate.range)
                        }.onEnded { event in
                            // A click (no drag) clears the range, as the approved mockup.
                            let dragged = LightfieldChartGeometry.dragSelection(startX: event.startLocation.x,
                                currentX: event.location.x, width: proxy.size.width, samples: samples, xFractions: xFractions)
                            if dragged == nil { clearSelection() }
                        })
                }
                .lightfieldComponentProbe(probeID + ".plot")
                if let secondaryAxis {
                    let labels = labels(for: secondaryAxis)
                    VStack(alignment: .leading) { axisText(labels.0, id: "secondary.top"); Spacer(minLength: 0); axisText(labels.1, id: "secondary.middle"); Spacer(minLength: 0); axisText(labels.2, id: "secondary.bottom") }
                        .foregroundStyle(palette.fg2).frame(width: 36)
                }
                if gutterWidth > 0 { Color.clear.frame(width: gutterWidth - 6).padding(.leading, 6) }
            }.frame(height: max(24, height))
            HStack(spacing: 8) {
                Text(LightfieldAxisLabel.display(xAxisLabels?.0 ?? startLabel)).lineLimit(1)
                Spacer(minLength: 0)
                if let selection {
                    Text(L10n.text("区间平均", "Range average") + " · " + valueFormat.detail(selection.average)).lineLimit(1)
                        .lightfieldComponentProbe("lightfield.trend.average")
                } else if let hint {
                    Text(hint).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text(LightfieldAxisLabel.display(hoveredIndex.flatMap { samples.indices.contains($0) ? xLabel(at: $0) : nil }
                    ?? xAxisLabels?.1 ?? L10n.text("现在", "Now"))).lineLimit(1)
            }.font(.system(size: 13)).monospacedDigit().foregroundStyle(palette.fg2)
            .padding(.top, 8).padding(.leading, axisWidth).padding(.trailing, gutterWidth)
        }
        .animation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.check,
            reduceMotion: reduceMotion || disablesAnimations), value: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? L10n.text("占用趋势", "Usage trend"))
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            guard !samples.isEmpty else { return }
            let current = hoveredIndex ?? samples.count - 1
            switch direction {
            case .increment: setHover(min(samples.count - 1, current + 1))
            case .decrement: setHover(max(0, current - 1))
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text(L10n.text("清除区间", "Clear range"))) { clearSelection() }
        .onChange(of: samples) { old, new in reanchor(old: old, new: new) }
    }
    private func axisText(_ text: String, id: String) -> some View {
        Text(LightfieldAxisLabel.display(text)).font(.system(size: axis == .percent ? 13 : 11, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.75) // lightfield-scale-ok: chart-axis
            .frame(width: 36, alignment: .trailing).accessibilityLabel(text)
            .lightfieldComponentProbe(probeID + ".axis." + id)
    }
    private var axisLabels: (String, String, String) { labels(for: axis) }
    private func labels(for axis: LightfieldTrendAxis) -> (String, String, String) {
        switch axis {
        case .labels(let top, let middle, let bottom): (top, middle, bottom)
        case .percent, .hidden: ("100%", "50%", "0")
        }
    }
    @ViewBuilder private func header(_ palette: FeatureLightfieldPalette) -> some View {
        HStack(spacing: 16) {
            if let title {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.fg2).lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            switch legend {
            case .none: EmptyView()
            case .pressure:
                ForEach([FeatureLightfieldStatus.normal, .warning, .failure], id: \.self) { status in
                    HStack(spacing: 6) {
                        Circle().fill(status.color(palette)).frame(width: 6, height: 6)
                        Text(status.pressureName)
                    }.foregroundStyle(status.color(palette))
                }
            case .series:
                ForEach(legendEntries, id: \.name) { entry in
                    HStack(spacing: 6) {
                        Capsule().fill(entry.color).frame(width: 12, height: 2)
                        Text(entry.name)
                    }.foregroundStyle(palette.fg2)
                    .lightfieldComponentProbe("lightfield.trend.legend." + entry.name)
                }
            }
        }.font(.system(size: 13)).lightfieldComponentProbe("lightfield.trend.header")
    }
    private var legendEntries: [(name: String, color: Color)] {
        (primaryName.map { [($0, lineColor)] } ?? []) + series.map { ($0.name, $0.color) }
    }
    private var accessibilityValue: String {
        if let selection { return L10n.text("区间平均", "Range average") + " · " + valueFormat.detail(selection.average) }
        let index = hoveredIndex ?? samples.indices.last
        guard let index, samples.indices.contains(index) else { return L10n.text("未提供", "Unavailable") }
        return samples[index].time.formatted(date: .omitted, time: .standard) + " · " + detail(at: index)
    }
    /// Primary value, then each extra line by name ("82.0% · GPU 4.0%").
    private func detail(at index: Int) -> String {
        ([valueFormat.detail(samples[index].value)] + series.compactMap { line in
            line.samples.indices.contains(index) ? line.name + " " + (secondaryValueFormat ?? valueFormat).compact(line.samples[index].value) : nil
        }).joined(separator: " · ")
    }
    private var startLabel: String { samples.first.map { relative($0.time) } ?? "" }
    /// Relative to the newest sample, as the approved axis ("1 分 55 秒前 … 现在").
    private func relative(_ time: Date) -> String {
        guard let last = samples.last?.time else { return "" }
        let seconds = max(0, Int(last.timeIntervalSince(time).rounded()))
        guard seconds > 0 else { return L10n.text("现在", "Now") }
        let minutes = seconds / 60, rest = seconds % 60
        if minutes == 0 { return L10n.text("\(rest) 秒前", "\(rest)s ago") }
        if rest == 0 { return L10n.text("\(minutes) 分钟前", "\(minutes) min ago") }
        return L10n.text("\(minutes) 分 \(rest) 秒前", "\(minutes)m \(rest)s ago")
    }
    private func setHover(_ index: Int?) {
        let time = index.flatMap { samples.indices.contains($0) ? samples[$0].time : nil }
        guard hoveredTime != time else { return }
        hoveredTime = time
        onHoverIndex(index)
    }
    private func setSelection(_ range: ClosedRange<Int>?) {
        let times = range.map { samples[$0.lowerBound].time...samples[$0.upperBound].time }
        guard selectedTimes != times else { return }
        selectedTimes = times
        let selection = selection
        onSelection(selection)
    }
    private func clearSelection() {
        guard selectedTimes != nil else { return }
        selectedTimes = nil
        onSelection(nil)
    }
    /// New samples keep the hovered moment and the range (by timestamp) and
    /// report their new indices; anything that scrolled out is cleared.
    private func reanchor(old: [LightfieldTrendSample], new: [LightfieldTrendSample]) {
        let oldHover = LightfieldChartGeometry.anchoredIndex(time: hoveredTime, in: old)
        let newHover = LightfieldChartGeometry.anchoredIndex(time: hoveredTime, in: new)
        if newHover == nil { hoveredTime = nil }
        if oldHover != newHover { onHoverIndex(newHover) }
        let oldRange = LightfieldChartGeometry.anchoredSelection(times: selectedTimes, in: old)
        let newRange = LightfieldChartGeometry.anchoredSelection(times: selectedTimes, in: new)
        if newRange == nil { selectedTimes = nil }
        if oldRange != newRange { onSelection(newRange) }
    }
    private func line(_ values: [LightfieldTrendSample], size: CGSize, fill: Bool) -> Path {
        var path = Path()
        var run: [CGPoint] = []
        func appendRun() {
            guard let first = run.first, let last = run.last else { return }
            path.move(to: first)
            for point in run.dropFirst() { path.addLine(to: point) }
            if fill {
                path.addLine(to: CGPoint(x: last.x, y: size.height))
                path.addLine(to: CGPoint(x: first.x, y: size.height)); path.closeSubpath()
            }
            run.removeAll(keepingCapacity: true)
        }
        for (index, sample) in values.enumerated() {
            if let value = sample.value, value.isFinite {
                run.append(point(index, value: value, size: size))
            } else { appendRun() }
        }
        appendRun()
        return path
    }
    private func xLabel(at index: Int) -> String {
        if let xValueFormat, let xFractions, xFractions.indices.contains(index) { return xValueFormat.detail(xFractions[index]) }
        return relative(samples[index].time)
    }
    private func point(_ index: Int, value: Double, size: CGSize) -> CGPoint {
        if let xFractions, xFractions.indices.contains(index) {
            return LightfieldChartGeometry.point(xFraction: xFractions[index], value: value, size: size)
        }
        return LightfieldChartGeometry.point(index: index, count: samples.count, value: value, size: size)
    }
    private func x(_ index: Int, size: CGSize) -> CGFloat {
        point(index, value: 0, size: size).x
    }
    private func plot(size: CGSize, palette: FeatureLightfieldPalette) -> some View {
        ZStack(alignment: .topLeading) {
            // Bottom pressure bands communicate thresholds, independently of
            // the measured line; they are data graphics rather than containers.
            if showsPressureBands {
                Rectangle().fill(FeatureLightfieldPalette.color(palette.failure).opacity(0.06))
                    .frame(height: size.height / 3)
                    .lightfieldComponentProbe("lightfield.trend.band.failure")
                Rectangle().fill(FeatureLightfieldPalette.color(palette.warning).opacity(0.06))
                    .frame(height: size.height / 3).offset(y: size.height / 3)
                    .lightfieldComponentProbe("lightfield.trend.band.warning")
                Rectangle().fill(FeatureLightfieldPalette.color(palette.normal).opacity(0.06))
                    .frame(height: size.height / 3).offset(y: size.height * 2 / 3)
                    .lightfieldComponentProbe("lightfield.trend.band.normal")
            }
            Path { path in
                for fraction in [CGFloat(0), 0.5, 1] { path.move(to: .init(x: 0, y: size.height * fraction)); path.addLine(to: .init(x: size.width, y: size.height * fraction)) }
            }.stroke(palette.hairColor, lineWidth: 1)
            if fillsArea {
                line(samples, size: size, fill: true).fill(LinearGradient(colors: [lineColor.opacity(0.12),
                    lineColor.opacity(0)], startPoint: .top, endPoint: .bottom))
            }
            ForEach(series) { extra in
                line(extra.samples, size: size, fill: false)
                    .stroke(extra.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .lightfieldComponentProbe("lightfield.trend.series." + extra.id)
            }
            line(samples, size: size, fill: false).stroke(lineColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let selection {
                let left = x(selection.range.lowerBound, size: size)
                let right = x(selection.range.upperBound, size: size)
                Rectangle().fill(lineColor.opacity(0.16))
                    .overlay { Rectangle().stroke(lineColor.opacity(0.4), lineWidth: 1) }
                    .frame(width: max(1, right - left), height: size.height).offset(x: left)
            }
            if showsPoints {
                ForEach(samples.indices, id: \.self) { index in
                    if let value = samples[index].value, value.isFinite {
                        Circle().fill(lineColor).frame(width: 6, height: 6).position(point(index, value: value, size: size))
                        if pointLabels.indices.contains(index) {
                            Text(pointLabels[index]).font(.system(size: 11)).foregroundStyle(palette.fg2)
                                .lineLimit(1).frame(width: min(76, size.width), height: 16)
                                .position(x: min(max(38, x(index, size: size)), max(38, size.width - 38)),
                                    y: min(max(8, point(index, value: value, size: size).y - 12), size.height - 8))
                                .lightfieldComponentProbe(probeID + ".pointLabel." + String(index))
                        }
                    }
                }
            }
            if let last = samples.indices.last, let value = samples[last].value, value.isFinite {
                let point = point(last, value: value, size: size)
                Circle().fill(lineColor.opacity(0.18)).frame(width: 12, height: 12).position(point)
                Circle().fill(lineColor).frame(width: 6, height: 6).position(point)
            }
            if let index = hoveredIndex, samples.indices.contains(index) {
                let cursor = x(index, size: size)
                Path { path in path.move(to: .init(x: cursor, y: 0)); path.addLine(to: .init(x: cursor, y: size.height)) }
                    .stroke(palette.fg2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .lightfieldComponentProbe("lightfield.trend.cursor")
                if let value = samples[index].value, value.isFinite {
                    let point = point(index, value: value, size: size)
                    Circle().fill(palette.fg).overlay { Circle().stroke(lineColor, lineWidth: 2) }
                        .frame(width: 6, height: 6).position(point)
                }
                if hoverStyle.contains(.topLine) {
                    Text(samples[index].time.formatted(date: .omitted, time: .shortened) + " · " + detail(at: index))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(palette.fg)
                        .lineLimit(1).minimumScaleFactor(0.8) // lightfield-scale-ok: chart-readout
                        .frame(width: min(150, size.width), alignment: .center)
                        .position(x: min(max(min(75, size.width / 2), cursor), max(size.width / 2, size.width - 75)), y: 10)
                }
            }
        }.frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            // Current value sits in the 62 pt gutter beside the newest sample;
            // an overlay, so it never changes the plot's layout.
            if showsCurrentValue, hoveredIndex == nil, let last = samples.indices.last {
                let y = samples[last].value.flatMap { $0.isFinite ? LightfieldChartGeometry.point(index: last,
                    count: samples.count, value: $0, size: size).y : nil } ?? size.height / 2
                Text(valueFormat.compact(samples[last].value))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(palette.fg)
                    .lineLimit(1).fixedSize()
                    .frame(height: 16).offset(x: size.width + 12, y: y - 8)
            }
        }
        .overlay(alignment: .topLeading) {
            if hoverStyle.contains(.bubble), let index = hoveredIndex, samples.indices.contains(index) {
                hoverBubble(index: index, size: size, palette: palette)
            }
        }
    }
    /// Approved memory-landing hover bubble: 180 wide, sidebar colour, 8 pt
    /// corners, time (13 fg2) over value (15 semibold); centred on the cursor,
    /// 50 pt above the point, clamped to the chart including axis and gutter.
    private func hoverBubble(index: Int, size: CGSize, palette: FeatureLightfieldPalette) -> some View {
        let width: CGFloat = 180
        let cursor = x(index, size: size)
        let pointY = samples[index].value.flatMap { $0.isFinite ? point(index, value: $0, size: size).y : nil } ?? size.height / 2
        let left = min(max(-axisWidth, cursor - width / 2), max(-axisWidth, size.width + gutterWidth - width))
        return VStack(alignment: .leading, spacing: 2) {
            Text(xLabel(at: index)).font(.system(size: 13)).foregroundStyle(palette.fg2)
            Text(detail(at: index)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(palette.fg).lineLimit(1).truncationMode(.tail)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .frame(width: width, alignment: .leading)
        .background(FeatureLightfieldPalette.color(palette.sidebar), in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: FeatureLightfieldPalette.color(palette.canvas[2]).opacity(0.5), radius: 9, y: 4)
        .offset(x: left, y: max(0, pointY - 50))
        .allowsHitTesting(false)
        .lightfieldComponentProbe("lightfield.trend.bubble")
    }
}

struct LightfieldChartItem: Identifiable {
    let id: String
    let label: String
    let value: Double
    let formattedValue: String
    let module: ReviewFilter
    let icon: LightfieldOptionIcon
    var color: Color? = nil
    var detail = ""
    /// D154 batch 3N: the item's real icon in its bubble, in place of `icon`.
    var picture: LightfieldChartPicture? = nil
}

/// D154 batch 3N: what a Space Lens bubble shows, as its list row does — an
/// app's own icon, else Finder's icon for the folder or the kind of file.
struct LightfieldChartPicture: Equatable {
    let path: String
    let isDirectory: Bool
}

struct LightfieldBubbleChart: View {
    @Environment(\.colorScheme) private var scheme
    let items: [LightfieldChartItem]
    var onHighlight: (String?) -> Void = { _ in }
    var onDrillDown: (String) -> Void = { _ in }
    /// Formats the merged tail's total (beyond 24 bubbles); nil shows only
    /// "其他 N 项". Its drill-down id is `LightfieldBubbleLayout.otherID`.
    var mergedValueFormatter: ((Double) -> String)? = nil
    /// Layout is cached by (values, size); hover lives in each bubble, so
    /// local hovering never re-evaluates this body or re-packs (review P2-3).
    @State private var layoutCache = LightfieldBubbleLayoutCache()
    var linkedID: String? = nil
    var emphasizedIDs: Set<String>? = nil
    var body: some View {
        GeometryReader { proxy in
            let values = items.map { (id: $0.id, value: $0.value) }
            let placements = layoutCache.placements(values: values, size: proxy.size)
            let mergedIDs = Set(LightfieldBubbleLayout.merged(values).mergedIDs)
            ZStack {
                ForEach(placements) { placement in
                    if let item = displayItem(id: placement.id, mergedIDs: mergedIDs) {
                        LightfieldBubble(item: item, placement: placement, onHighlight: onHighlight, onDrillDown: onDrillDown,
                            linkedID: linkedID, emphasizedIDs: emphasizedIDs)
                            .position(placement.center)
                    }
                }
                if placements.isEmpty {
                    Text(L10n.text("暂无可绘制数据", "No measured data"))
                        .font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
    private func displayItem(id: String, mergedIDs: Set<String>) -> LightfieldChartItem? {
        guard id == LightfieldBubbleLayout.otherID else { return items.first { $0.id == id } }
        let total = items.filter { mergedIDs.contains($0.id) && $0.value.isFinite && $0.value > 0 }.reduce(0) { $0 + $1.value }
        return LightfieldChartItem(id: id, label: L10n.text("其他 \(mergedIDs.count) 项", "\(mergedIDs.count) more"),
            value: total, formattedValue: mergedValueFormatter?(total) ?? "", module: .utilityHub, icon: .fileanalysisOther)
    }
}

// Additive initializer for a linked file list. The original memberwise API and
// per-bubble hover state remain intact; external updates reuse the layout cache.
extension LightfieldBubbleChart {
    init(items: [LightfieldChartItem], onHighlight: @escaping (String?) -> Void = { _ in },
         onDrillDown: @escaping (String) -> Void = { _ in },
         mergedValueFormatter: ((Double) -> String)? = nil,
         highlightedID: String?, emphasizedIDs: Set<String>? = nil) {
        self.init(items: items, onHighlight: onHighlight, onDrillDown: onDrillDown,
            mergedValueFormatter: mergedValueFormatter, linkedID: highlightedID, emphasizedIDs: emphasizedIDs)
    }
}

/// One bubble owns its hover state: hovering changes only this view.
private struct LightfieldBubble: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let item: LightfieldChartItem
    let placement: LightfieldBubblePlacement
    let onHighlight: (String?) -> Void
    let onDrillDown: (String) -> Void
    var linkedID: String? = nil
    var emphasizedIDs: Set<String>? = nil
    @State private var highlighted: String?
    var body: some View {
        let diameter = placement.radius * 2
        let palette = FeatureLightfieldPalette.resolve(scheme)
        let color = item.id == LightfieldBubbleLayout.otherID ? palette.fg3
            : item.color ?? FeatureLightfieldPalette.accent(item.module)
        let dark = scheme == .dark
        // Approved glass bubble (files r3/r4 CSS): type-colour linear body,
        // lower-right colour pool, upper-left highlight and a tinted 1 pt rim.
        // D154 batch 3S: a bubble this size always shows its name, set in its
        // own font and cut at the end when it runs past the bubble (was hidden
        // whenever an estimate of 15 pt a character ran past 70% of it, which
        // dropped "node_modules" from the largest bubble).
        let labelled = diameter >= LightfieldBubbleLayout.labelThreshold
        // D193③: with its name and size, a bubble under about 100 pt shrinks
        // the glyph as it does a picture, so the two lines keep their room.
        let glyphSide: CGFloat = diameter < 42 ? 14 : diameter >= 138 ? 32 : 24
        let iconSide = labelled
            ? min(glyphSide, LightfieldBubbleLayout.pictureSide(diameter: diameter, labelled: true)) : glyphSide
        let label = item.formattedValue.isEmpty ? item.label : item.label + " · " + item.formattedValue
        Button { onDrillDown(item.id) } label: {
            ZStack {
                Circle().fill(LinearGradient(colors: [color.opacity(dark ? 0.14 : 0.10),
                    color.opacity(dark ? 0.27 : 0.21)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().fill(RadialGradient(colors: [color.opacity(dark ? 0.35 : 0.25), color.opacity(0)],
                    center: .init(x: 0.68, y: 0.88), startRadius: 0, endRadius: diameter * 0.66))
                Circle().fill(RadialGradient(colors: [Color.white.opacity(dark ? 0.19 : 0.69), Color.white.opacity(0)],
                    center: .init(x: 0.28, y: 0.18), startRadius: 0, endRadius: diameter * (dark ? 0.4 : 0.44)))
                Circle().strokeBorder(color.opacity(dark ? 0.72 : 0.6), lineWidth: 1)
                Circle().strokeBorder(Color.white.opacity(dark ? 0.28 : 0.45), lineWidth: 1)
                VStack(spacing: 4) {
                    if let picture = item.picture {
                        LightfieldBubblePicture(picture: picture,
                            side: LightfieldBubbleLayout.pictureSide(diameter: diameter, labelled: labelled))
                            .lightfieldComponentProbe("lightfield.bubble.picture." + item.id)
                    } else {
                        // 32 pt icons load the 84 px export (review P2-7).
                        LightfieldOptionIconView(icon: item.icon, pointSize: iconSide)
                    }
                    if labelled {
                        Text(item.label).font(.system(size: 15, weight: .medium)).foregroundStyle(palette.fg)
                            .lineLimit(1).truncationMode(.tail)
                            .lightfieldComponentProbe("lightfield.bubble.label." + item.id)
                        Text(item.formattedValue).font(.system(size: 13)).monospacedDigit().foregroundStyle(palette.fg2)
                            .lineLimit(1).minimumScaleFactor(0.8) // lightfield-scale-ok: disk-value
                    }
                }.frame(width: diameter * 0.7, height: diameter * 0.7)
            }.frame(width: diameter, height: diameter).contentShape(Circle())
        }
        .buttonStyle(FeatureLightfieldRowButtonStyle(circular: true))
        .opacity(emphasizedIDs.map { $0.contains(item.id) ? 1 : 0.28 } ?? 1)
        .scaleEffect((highlighted ?? linkedID) == item.id ? LightfieldBubbleLayout.hoverScale : 1)
        .animation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.check,
            reduceMotion: reduceMotion || disablesAnimations), value: highlighted == item.id)
        .animation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.check,
            reduceMotion: reduceMotion || disablesAnimations), value: linkedID == item.id)
        .onHover { hovering in
            if hovering { highlighted = item.id; onHighlight(item.id) }
            else if highlighted == item.id { highlighted = nil; onHighlight(nil) }
        }
        .onDisappear { if highlighted != nil { highlighted = nil; onHighlight(nil) } }
        .accessibilityLabel(label)
        .help(item.detail.isEmpty ? label : item.detail)
        .accessibilityHint(item.detail.isEmpty ? L10n.text("打开此项", "Open item") : item.detail)
        // Too small to target: the merged "other" bubble carries the tail.
        .accessibilityHidden(diameter < LightfieldBubbleLayout.minimumAccessibleDiameter)
        .lightfieldComponentProbe("lightfield.bubble." + item.id)
    }
}

/// The list row's icon at the bubble's size: an app's own icon (cached),
/// else Finder's icon for its kind, read once per kind.
private struct LightfieldBubblePicture: View {
    let picture: LightfieldChartPicture
    let side: CGFloat

    var body: some View {
        CachedAppIconView(path: picture.path.hasSuffix(".app") ? picture.path : "", size: side) {
            Image(nsImage: SpaceLensKindIcon.image(isDirectory: picture.isDirectory, path: picture.path))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: side, height: side)
        }
        .accessibilityHidden(true)
    }
}

struct LightfieldDonutChart: View {
    @Environment(\.colorScheme) private var scheme
    let items: [LightfieldChartItem]
    let centerValue: String
    let centerLabel: String
    var selectedID: String? = nil
    var onSelect: ((String) -> Void)? = nil
    var body: some View {
        let arcs = LightfieldDonutGeometry.arcs(values: items.map { ($0.id, $0.value) })
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().stroke(FeatureLightfieldPalette.resolve(scheme).hairColor, lineWidth: LightfieldDonutGeometry.lineWidth)
                ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                    if let item = items.first(where: { $0.id == arc.id }) {
                        // A hairline of canvas between adjacent arcs, as approved.
                        let inset = arcs.count > 1 && arc.fraction > 0.012 ? 0.002 : 0
                        Circle().trim(from: CGFloat(arc.start + inset), to: CGFloat(arc.end - inset))
                            .stroke(item.color ?? FeatureLightfieldPalette.accent(item.module), lineWidth: LightfieldDonutGeometry.lineWidth)
                            .opacity(selectedID == nil || selectedID == item.id ? 1 : 0.28)
                            .rotationEffect(.degrees(-90))
                    }
                }
                VStack(spacing: 4) {
                    Text(centerValue).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: donut-center
                    Text(centerLabel).font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                        .lineLimit(2).multilineTextAlignment(.center)
                }.frame(width: 76, height: 60).lightfieldComponentProbe("lightfield.donut.text")
            }
            .padding(LightfieldDonutGeometry.lineWidth / 2)
            .frame(width: LightfieldDonutGeometry.diameter, height: LightfieldDonutGeometry.diameter)
            .accessibilityElement(children: .ignore).accessibilityLabel(centerValue + " · " + centerLabel)
            .lightfieldComponentProbe("lightfield.donut")
            VStack(spacing: 0) {
                ForEach(items) { item in
                    if let onSelect {
                        Button { onSelect(item.id) } label: { legend(item, share: arcs.first { $0.id == item.id }?.fraction) }
                            .buttonStyle(FeatureLightfieldRowButtonStyle())
                            .accessibilityLabel(item.label + " · " + item.formattedValue)
                            .accessibilityValue(selectedID == item.id ? L10n.text("已高亮", "Highlighted") : L10n.text("未高亮", "Not highlighted"))
                    } else { legend(item, share: arcs.first { $0.id == item.id }?.fraction).accessibilityElement(children: .combine) }
                }
            }.frame(maxWidth: .infinity)
        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
    }
    private func legend(_ item: LightfieldChartItem, share: Double?) -> some View {
        HStack(spacing: 6) {
            Circle().fill(item.color ?? FeatureLightfieldPalette.accent(item.module))
                .frame(width: 6, height: 6).accessibilityHidden(true)
            Text(item.label).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2).lineLimit(1)
            Text(item.formattedValue).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: donut-value
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(share.map { String(format: "%.1f%%", $0 * 100) } ?? (item.value == 0 ? "0.0%" : "—"))
                .monospacedDigit().foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                .lineLimit(1).minimumScaleFactor(0.5).frame(width: 44, alignment: .trailing) // lightfield-scale-ok: donut-share
        }.font(.system(size: 13)).frame(height: 24)
            .opacity(selectedID == nil || selectedID == item.id ? 1 : 0.28)
            .lightfieldComponentProbe("lightfield.donut.legend." + item.id)
    }

}

/// Compact only numeric axis values; the full value remains accessible.
enum LightfieldAxisLabel {
    static func display(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        let numeric = String(cleaned.prefix { "0123456789.eE+-".contains($0) })
        let suffix = String(cleaned.dropFirst(numeric.count))
        guard let number = Double(numeric), number.isFinite, abs(number) >= 10_000 else { return text }
        func compact(_ precision: String) -> String {
            String(format: precision, locale: Locale(identifier: "en_US_POSIX"), number).lowercased()
                .replacingOccurrences(of: "e+", with: "e").replacingOccurrences(of: "e0", with: "e")
        }
        let value = compact("%.2g")
        return (value.count <= 7 ? value : compact("%.1g")) + suffix
    }
}
