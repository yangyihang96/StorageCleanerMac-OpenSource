import SwiftUI

// MARK: - MetricRing (UI-V2-SPEC 1.5, §3.2.5)

/// An angular-gradient ring with round caps on a 12% track, glowing softly
/// at night. On first appearance it draws from 0 to the value; later values
/// travel from the previous one. `nil` shows the empty track (unknown is not
/// zero, RULES §5).
struct MetricRing<Center: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppSurfaces private var surfaces
    @State private var drawnFraction: Double = 0

    let fraction: Double?
    var colors: [Color]
    var lineWidth: CGFloat = 10
    var trackOpacity: Double = 0.12
    @ViewBuilder let center: Center

    private var target: Double {
        guard let fraction, fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(surfaces.isNight ? Color.white.opacity(trackOpacity) : Color.black.opacity(trackOpacity * 0.7),
                        lineWidth: lineWidth)
            if fraction != nil {
                Circle()
                    .trim(from: 0, to: max(0.0001, drawnFraction))
                    .stroke(
                        AngularGradient(
                            colors: colors.count > 1 ? colors : colors + colors,
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360 * max(0.05, drawnFraction))
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: surfaces.isNight ? (colors.last ?? .clear).opacity(0.45) : .clear,
                            radius: lineWidth * 0.8)
            }
            center
        }
        .padding(lineWidth / 2)
        .onAppear { animate(to: target, fromZero: true) }
        .onChange(of: target) { _, value in animate(to: value, fromZero: false) }
    }

    private func animate(to value: Double, fromZero: Bool) {
        guard let animation = AppMotion.resolved(.data, reduceMotion: reduceMotion) else {
            drawnFraction = value
            return
        }
        if fromZero { drawnFraction = 0 }
        withAnimation(animation) { drawnFraction = value }
    }
}

extension MetricRing where Center == EmptyView {
    init(fraction: Double?, colors: [Color], lineWidth: CGFloat = 10) {
        self.fraction = fraction
        self.colors = colors
        self.lineWidth = lineWidth
        self.center = EmptyView()
    }
}

// MARK: - TrendChart (UI-V2-SPEC 1.5, §3.2.5)

/// A 2 pt smooth curve over an area that fades from 35% to 0, on grid lines
/// of 6% ink. New samples push in from the right: the curve slides one step
/// with the data curve, then rests. No timer or loop drives it.
///
/// Pointing at the chart reads out the sample under the pointer (both
/// series); VoiceOver reads each series' current, average, lowest and
/// highest value, and says when the latest sample has no reading (review
/// P2-5, as the earlier precision chart did).
struct TrendChart: View {
    struct Sample: Equatable {
        let date: Date
        let value: Double?
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppSurfaces private var surfaces
    @State private var shift: CGFloat = 0
    @State private var lastSampleDate: Date?
    /// Where the pointer is, as a fraction of the plot width (not a sample
    /// index): the sample under it is found again on every render, so new
    /// samples, dropped history and resizes keep the readout under the
    /// pointer (review 2, P2-4).
    @State private var hoverFraction: CGFloat?

    let samples: [Sample]
    /// An optional second series, drawn as a thin dashed line without fill.
    var secondarySamples: [Sample] = []
    var secondaryColor: Color = .yellow
    var range: ClosedRange<Double> = 0...100
    /// The visible time window in seconds.
    var duration: TimeInterval = 120
    var color: Color
    var gridLines: [Double] = [0, 25, 50, 75, 100]
    var valueLabel: (Double) -> String = { "\(Int($0))%" }
    var showsAxisLabels = true
    var accessibilityLabel: String
    /// Series names for the hover readout and the VoiceOver summary.
    var title = ""
    var secondaryTitle = ""
#if DEBUG
    /// Tests and review captures: a pointer resting at this fraction of the
    /// plot from the first frame (hover events cannot be synthesized there).
    var debugHoverFraction: CGFloat?
#endif

    var body: some View {
        GeometryReader { proxy in
            let plot = plotRect(in: proxy.size)
            ZStack(alignment: .topLeading) {
                gridLayer(plot: plot)
                TrendAreaShape(points: normalizedPoints, shift: shift)
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)
                if !secondarySamples.isEmpty {
                    TrendLineShape(points: normalized(secondarySamples), shift: shift)
                        .stroke(secondaryColor.opacity(0.85),
                                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [4, 4]))
                        .frame(width: plot.width, height: plot.height)
                        .offset(x: plot.minX, y: plot.minY)
                }
                TrendLineShape(points: normalizedPoints, shift: shift)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)
                    .shadow(color: surfaces.isNight ? color.opacity(0.45) : .clear, radius: 4)
                if showsAxisLabels {
                    axisLabels(plot: plot)
                }
            }
            .clipped()
            .drawingGroup()
            .overlay(alignment: .topLeading) {
                if let hoverFraction,
                   let index = Self.nearestSampleIndex(toX: plot.minX + hoverFraction * plot.width, plot: plot,
                                                       samples: samples, duration: duration) {
                    hoverReadout(index: index, plot: plot, size: proxy.size)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let fraction = plot.width > 0 ? min(1, max(0, (location.x - plot.minX) / plot.width)) : nil
                    if fraction != hoverFraction { hoverFraction = fraction }
                case .ended:
                    hoverFraction = nil
                }
            }
        }
#if DEBUG
        .onAppear {
            if let debugHoverFraction, hoverFraction == nil { hoverFraction = debugHoverFraction }
        }
#endif
        .onChange(of: samples.last?.date) { _, newDate in
            pushNewestSample(at: newDate)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Self.accessibilitySummary(
            series: [(title, samples), (secondaryTitle, secondarySamples)],
            valueLabel: valueLabel
        ))
    }

    /// The sample nearest to `x` in the plot, by time.
    static func nearestSampleIndex(toX x: CGFloat, plot: CGRect, samples: [Sample], duration: TimeInterval) -> Int? {
        guard let newest = samples.last?.date, plot.width > 0, duration > 0 else { return nil }
        let fraction = min(1, max(0, (x - plot.minX) / plot.width))
        let time = newest.addingTimeInterval(-duration * (1 - Double(fraction)))
        let nearest = samples.indices.min {
            abs(samples[$0].date.timeIntervalSince(time)) < abs(samples[$1].date.timeIntervalSince(time))
        }
        guard let nearest, abs(samples[nearest].date.timeIntervalSince(time)) <= duration / 4 else { return nil }
        return nearest
    }

    /// One line per series: current, average, lowest and highest. A series
    /// whose latest sample has no reading says so instead of repeating an
    /// older value; a chart without any reading says it is sampling.
    static func accessibilitySummary(
        series: [(title: String, samples: [Sample])],
        valueLabel: (Double) -> String
    ) -> String {
        let lines = series.compactMap { title, samples -> String? in
            let values = samples.compactMap(\.value).filter(\.isFinite)
            guard let minimum = values.min(), let maximum = values.max() else { return nil }
            let average = values.reduce(0, +) / Double(values.count)
            let name = title.isEmpty ? L10n.text("趋势", "Trend") : title
            if let current = samples.last?.value, current.isFinite {
                return L10n.text(
                    "\(name)：当前 \(valueLabel(current))，平均 \(valueLabel(average))，最低 \(valueLabel(minimum))，最高 \(valueLabel(maximum))",
                    "\(name): current \(valueLabel(current)), average \(valueLabel(average)), minimum \(valueLabel(minimum)), maximum \(valueLabel(maximum))"
                )
            }
            return L10n.text(
                "\(name)：当前无数据，平均 \(valueLabel(average))，最低 \(valueLabel(minimum))，最高 \(valueLabel(maximum))",
                "\(name): no current reading, average \(valueLabel(average)), minimum \(valueLabel(minimum)), maximum \(valueLabel(maximum))"
            )
        }
        return lines.isEmpty ? PanelChartSampling.statusText : lines.joined(separator: L10n.text("；", "; "))
    }

    /// The readout under the pointer: how long ago, and both series' values
    /// (or "no data" for a missing reading).
    static func readoutLines(
        index: Int,
        samples: [Sample],
        secondarySamples: [Sample],
        titles: (String, String),
        valueLabel: (Double) -> String
    ) -> [String] {
        guard samples.indices.contains(index), let newest = samples.last?.date else { return [] }
        let sample = samples[index]
        let secondsAgo = max(0, Int(newest.timeIntervalSince(sample.date).rounded()))
        var lines = [secondsAgo == 0 ? L10n.text("现在", "Now") : L10n.text("\(secondsAgo) 秒前", "\(secondsAgo) s ago")]
        func reading(_ value: Double?) -> String {
            value.map { $0.isFinite ? valueLabel($0) : L10n.text("无数据", "No data") } ?? L10n.text("无数据", "No data")
        }
        lines.append("\(titles.0.isEmpty ? L10n.text("数值", "Value") : titles.0) \(reading(sample.value))")
        if !secondarySamples.isEmpty {
            let secondary = secondarySamples.first { $0.date == sample.date }?.value
            lines.append("\(titles.1) \(reading(secondary))")
        }
        return lines
    }

    private func hoverReadout(index: Int, plot: CGRect, size: CGSize) -> some View {
        let lines = Self.readoutLines(index: index, samples: samples, secondarySamples: secondarySamples,
                                      titles: (title, secondaryTitle), valueLabel: valueLabel)
        let x = Self.xPosition(of: samples[index], plot: plot, newest: samples.last?.date, duration: duration)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(surfaces.textSecondary.opacity(0.5))
                .frame(width: 1, height: plot.height)
                .offset(x: x, y: plot.minY)
            // The readout keeps its lines whole (review 2, P2-5) and is
            // placed by its real width inside the chart (review 3).
            TrendReadoutPlacement(ruleX: x, top: plot.minY + 2) {
                TrendChartReadout(lines: lines)
#if DEBUG
                    .layoutProbe("trend.readout.\(Int(samples[index].date.timeIntervalSinceReferenceDate))")
#endif
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func xPosition(of sample: Sample, plot: CGRect, newest: Date?, duration: TimeInterval) -> CGFloat {
        guard let newest, duration > 0 else { return plot.maxX }
        let fraction = 1 - newest.timeIntervalSince(sample.date) / duration
        return plot.minX + CGFloat(min(1, max(0, fraction))) * plot.width
    }

    private func plotRect(in size: CGSize) -> CGRect {
        // Wide enough for "100%" on one line in the caption font.
        let leading: CGFloat = showsAxisLabels ? 40 : 0
        let bottom: CGFloat = showsAxisLabels ? 16 : 0
        return CGRect(x: leading, y: 4, width: max(0, size.width - leading), height: max(0, size.height - bottom - 4))
    }

    /// Points in unit space: x from the window start (0) to now (1), y from
    /// the bottom (0) to the top (1). Missing values break the curve.
    private var normalizedPoints: [CGPoint?] {
        normalized(samples)
    }

    /// Both series share the time axis of the primary one.
    private func normalized(_ series: [Sample]) -> [CGPoint?] {
        guard let newest = samples.last?.date else { return [] }
        let start = newest.addingTimeInterval(-duration)
        let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
        return series.map { sample in
            guard let value = sample.value, value.isFinite else { return nil }
            let x = sample.date.timeIntervalSince(start) / duration
            guard x >= -0.05 else { return nil }
            let y = (min(range.upperBound, max(range.lowerBound, value)) - range.lowerBound) / span
            return CGPoint(x: x, y: y)
        }
    }

    private func pushNewestSample(at date: Date?) {
        defer { lastSampleDate = date }
        guard let date, let previous = lastSampleDate, date > previous,
              let animation = AppMotion.resolved(.data, reduceMotion: reduceMotion) else {
            shift = 0
            return
        }
        // Start one step to the right of the final position and slide left.
        let step = CGFloat(min(1, date.timeIntervalSince(previous) / duration))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { shift = step }
        withAnimation(animation) { shift = 0 }
    }

    private func gridLayer(plot: CGRect) -> some View {
        let ink: Color = surfaces.isNight ? .white : .black
        return Path { path in
            for line in gridLines {
                let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
                let y = plot.maxY - CGFloat((line - range.lowerBound) / span) * plot.height
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
        }
        .stroke(ink.opacity(0.06), lineWidth: 1)
    }

    private func axisLabels(plot: CGRect) -> some View {
        let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
        return ZStack(alignment: .topLeading) {
            ForEach(gridLines.filter { $0 == range.lowerBound || $0 == range.upperBound || $0 == (range.lowerBound + range.upperBound) / 2 }, id: \.self) { line in
                Text(valueLabel(line))
                    .font(AppDesignTokens.TypeScale.caption)
                    .foregroundStyle(surfaces.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: plot.minX - 6, alignment: .trailing)
                    .offset(y: plot.maxY - CGFloat((line - range.lowerBound) / span) * plot.height - 7)
            }
            HStack {
                Text(L10n.text("\(Int(duration / 60)) 分钟前", "\(Int(duration / 60)) min ago"))
                Spacer()
                Text(L10n.text("现在", "Now"))
            }
            .font(AppDesignTokens.TypeScale.caption)
            .foregroundStyle(surfaces.textTertiary)
            .frame(width: plot.width)
            .offset(x: plot.minX, y: plot.maxY + 2)
        }
        .accessibilityHidden(true)
    }
}

/// The pointer readout of a `TrendChart`: each line at its full width, so a
/// long English line ("Pressure estimate No data") is never cut.
struct TrendChartReadout: View {
    @AppSurfaces private var surfaces
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                Text(line)
                    .font(offset == 0 ? AppDesignTokens.TypeScale.caption : AppDesignTokens.TypeScale.captionEmphasis)
                    .foregroundStyle(offset == 0 ? surfaces.textTertiary : surfaces.textPrimary)
                    .monospacedDigit()
                    // Whole lines; only a chart narrower than a line wraps it.
                    .fixedSize(horizontal: false, vertical: true)
#if DEBUG
                    .layoutProbe("trend.readout.line.\(offset)")
#endif
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            SurfaceBackground(level: .elevated, cornerRadius: AppDesignTokens.Corner.row)
        }
    }
}

/// Places the pointer readout inside the chart by its measured width
/// (review 3): beside the rule on the right when it fits, else on the left,
/// else across the rule as near its middle as the chart allows. A readout
/// wider than the whole chart is offered the chart's width and wraps.
struct TrendReadoutPlacement: Layout {
    let ruleX: CGFloat
    let top: CGFloat
    var gap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let readout = subviews.first else { return }
        let ideal = readout.sizeThatFits(.unspecified)
        let width = min(ideal.width, bounds.width)
        let size = width < ideal.width ? readout.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
        let x = Self.originX(ruleX: ruleX, width: size.width, available: bounds.width, gap: gap)
        readout.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + top), anchor: .topLeading,
                      proposal: ProposedViewSize(width: size.width, height: size.height))
    }

    /// The readout's left edge in a chart `available` wide.
    static func originX(ruleX: CGFloat, width: CGFloat, available: CGFloat, gap: CGFloat) -> CGFloat {
        if ruleX + gap + width <= available { return ruleX + gap }
        if ruleX - gap - width >= 0 { return ruleX - gap - width }
        return min(max(0, ruleX - width / 2), max(0, available - width))
    }
}

/// Catmull-Rom smoothing, drawn as cubic Béziers between valid samples.
private enum TrendPath {
    static func segments(_ points: [CGPoint?]) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        for point in points {
            if let point {
                current.append(point)
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func addSmoothCurve(_ points: [CGPoint], to path: inout Path, moveToFirst: Bool) {
        guard let first = points.first else { return }
        if moveToFirst { path.move(to: first) } else { path.addLine(to: first) }
        guard points.count > 1 else { return }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
    }

    static func scaled(_ point: CGPoint, in rect: CGRect, shift: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + (point.x + shift) * rect.width,
                y: rect.maxY - min(1, max(0, point.y)) * rect.height)
    }
}

private struct TrendLineShape: Shape {
    let points: [CGPoint?]
    var shift: CGFloat

    var animatableData: CGFloat {
        get { shift }
        set { shift = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for segment in TrendPath.segments(points) {
            TrendPath.addSmoothCurve(segment.map { TrendPath.scaled($0, in: rect, shift: shift) },
                                     to: &path, moveToFirst: true)
        }
        return path
    }
}

private struct TrendAreaShape: Shape {
    let points: [CGPoint?]
    var shift: CGFloat

    var animatableData: CGFloat {
        get { shift }
        set { shift = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for segment in TrendPath.segments(points) {
            let scaled = segment.map { TrendPath.scaled($0, in: rect, shift: shift) }
            guard let first = scaled.first, let last = scaled.last else { continue }
            path.move(to: CGPoint(x: first.x, y: rect.maxY))
            TrendPath.addSmoothCurve(scaled, to: &path, moveToFirst: false)
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
