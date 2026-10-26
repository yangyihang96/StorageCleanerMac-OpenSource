import Foundation

/// Pure inputs/geometry shared by rendering and independent assertions. No
/// interpolated value is ever presented as an actual unavailable measurement.
enum LightfieldChartGeometry {
    enum SegmentState: Equatable, Sendable { case pending, current, complete }
    static func fraction(_ value: Double?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return CGFloat(min(1, max(0, value)))
    }
    static func segment(index: Int, count: Int, progress: Double?) -> SegmentState {
        guard count > 0, index >= 0, index < count, let fraction = fraction(progress) else { return .pending }
        let completed = Int(floor(fraction * CGFloat(count)))
        if index < completed { return .complete }
        return index == completed && fraction < 1 ? .current : .pending
    }
    /// Cells that animate: only the current one (review P2-4). Complete and
    /// pending cells, and a finished or unknown bar, are static.
    static func breathingSegments(count: Int, progress: Double?) -> [Int] {
        (0..<max(0, count)).filter { segment(index: $0, count: count, progress: progress) == .current }
    }
    static func index(at x: CGFloat, width: CGFloat, count: Int, xFractions: [Double]? = nil) -> Int? {
        guard count > 0, width > 0, width.isFinite, x.isFinite else { return nil }
        if let xFractions, xFractions.count == count, xFractions.allSatisfy({ $0.isFinite }) {
            let cursor = Double(max(0, min(width, x)) / width)
            return xFractions.indices.min { abs(min(1, max(0, xFractions[$0])) - cursor) < abs(min(1, max(0, xFractions[$1])) - cursor) }
        }
        return min(count - 1, max(0, Int((max(0, min(width, x)) / width * CGFloat(count - 1)).rounded())))
    }
    static func point(index: Int, count: Int, value: Double, size: CGSize) -> CGPoint {
        CGPoint(x: count > 1 ? CGFloat(index) / CGFloat(count - 1) * size.width : size.width / 2,
                y: (1 - (fraction(value) ?? 0)) * size.height)
    }
    static func point(xFraction: Double, value: Double, size: CGSize) -> CGPoint {
        CGPoint(x: (fraction(xFraction) ?? 0) * size.width, y: (1 - (fraction(value) ?? 0)) * size.height)
    }
    static func selection(start: Int, end: Int, samples: [LightfieldTrendSample]) -> LightfieldTrendSelection? {
        guard !samples.isEmpty else { return nil }
        let lower = max(0, min(samples.count - 1, min(start, end)))
        let upper = max(lower, min(samples.count - 1, max(start, end)))
        let values = samples[lower...upper].compactMap { sample -> Double? in
            guard let value = sample.value, value.isFinite else { return nil }
            return value
        }
        return LightfieldTrendSelection(range: lower...upper,
            average: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count), measuredCount: values.count)
    }
}

/// Review fixes (B2 复核): click-vs-drag and time-anchored history.
extension LightfieldChartGeometry {
    /// A press that moves less than this is a click: it never creates a
    /// one-sample range, and releasing it clears any existing range.
    static let minimumDragDistance: CGFloat = 3
    static func dragSelection(startX: CGFloat, currentX: CGFloat, width: CGFloat,
                              samples: [LightfieldTrendSample], xFractions: [Double]? = nil) -> LightfieldTrendSelection? {
        guard abs(currentX - startX) >= minimumDragDistance,
              let start = index(at: startX, width: width, count: samples.count, xFractions: xFractions),
              let current = index(at: currentX, width: width, count: samples.count, xFractions: xFractions) else { return nil }
        return selection(start: start, end: current, samples: samples)
    }
    /// Hover is anchored to a sample's timestamp, so a live refresh that
    /// appends/drops samples keeps the same moment (nil once it scrolls out).
    static func anchoredIndex(time: Date?, in samples: [LightfieldTrendSample]) -> Int? {
        guard let time else { return nil }
        return samples.firstIndex { $0.time == time }
    }
    /// A range keeps its newest end; if its oldest end scrolled out of the
    /// window it is clamped to the first sample. Gone entirely → nil.
    static func anchoredSelection(times: ClosedRange<Date>?, in samples: [LightfieldTrendSample]) -> LightfieldTrendSelection? {
        guard let times, let upper = samples.lastIndex(where: { $0.time <= times.upperBound }),
              samples[upper].time >= times.lowerBound else { return nil }
        let lower = samples.firstIndex { $0.time >= times.lowerBound } ?? upper
        return selection(start: lower, end: upper, samples: samples)
    }
}

/// How a normalized 0...1 trend value is written. `.percent` is the original
/// memory behaviour; scaled formats add a unit (e.g. "18.6 GB · 58.1%").
enum LightfieldTrendValueFormat: Equatable, Sendable {
    case percent
    case scaled(maximum: Double, unit: String, fractionDigits: Int = 1)
    case scaledWithPercent(maximum: Double, unit: String, fractionDigits: Int = 1)
    static func percentText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return L10n.text("未提供", "Unavailable") }
        return String(format: "%.1f%%", value * 100)
    }
    private func scaledText(_ value: Double, maximum: Double, unit: String, digits: Int) -> String {
        String(format: "%.\(max(0, digits))f", value * maximum) + (unit.isEmpty ? "" : " " + unit)
    }
    /// Gutter/current label.
    func compact(_ value: Double?) -> String {
        guard let value, value.isFinite else { return Self.percentText(nil) }
        switch self {
        case .percent, .scaledWithPercent: return Self.percentText(value)
        case .scaled(let maximum, let unit, let digits): return scaledText(value, maximum: maximum, unit: unit, digits: digits)
        }
    }
    /// Hover bubble / AX detail.
    func detail(_ value: Double?) -> String {
        guard let value, value.isFinite else { return Self.percentText(nil) }
        switch self {
        case .percent: return Self.percentText(value)
        case .scaled(let maximum, let unit, let digits): return scaledText(value, maximum: maximum, unit: unit, digits: digits)
        case .scaledWithPercent(let maximum, let unit, let digits):
            return scaledText(value, maximum: maximum, unit: unit, digits: digits) + " · " + Self.percentText(value)
        }
    }
}

struct LightfieldTrendSample: Equatable, Sendable {
    let time: Date
    /// Normalized measurement (0...1), nil creates a gap rather than a zero.
    let value: Double?
}
struct LightfieldTrendSelection: Equatable, Sendable {
    let range: ClosedRange<Int>
    let average: Double?
    let measuredCount: Int
}

struct LightfieldBubblePlacement: Equatable, Identifiable {
    let id: String
    let center: CGPoint
    let radius: CGFloat
    var frame: CGRect { CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2) }
}

enum LightfieldBubbleLayout {
    static let hoverScale: CGFloat = 1.04
    /// D193③: bubbles from about 80 pt across show their name and size (was
    /// 100 pt; the 92 pt "worktrees" bubble showed only its icon).
    static let labelThreshold: CGFloat = 80
    /// Approved field: the largest bubble is at most 180 pt, with about 7 pt
    /// between bubbles at that size (0.08 of the largest radius).
    static let maximumDiameter: CGFloat = 180
    static let gap: CGFloat = 0.08
    /// B2 review P2-3: the approved JS keeps every bubble at least 14 pt in
    /// radius; beyond 24 bubbles the smallest tail merges into one "other".
    static let minimumRadius: CGFloat = 14
    static let maximumBubbles = 24
    static let otherID = "lightfield.bubble.other"
    /// Bubbles this small are not useful AX targets (merged tail covers them).
    static let minimumAccessibleDiameter: CGFloat = 20

    /// D154 batch 3N: a real icon (CleanMyMac's Space Lens bubbles) fills more
    /// of the bubble than the option glyph and, when the name and size show,
    /// leaves them their two lines; at most 56 pt.
    static func pictureSide(diameter: CGFloat, labelled: Bool) -> CGFloat {
        let room = labelled ? diameter * 0.7 - 44 : diameter * 0.62
        return max(12, min(56, room.rounded(.down)))
    }

    struct Merged: Equatable {
        /// Valid, de-duplicated, value-descending (id ascending on ties); the
        /// merged tail, if any, is last under `otherID`.
        let values: [Entry]
        let mergedIDs: [String]
        struct Entry: Equatable { let id: String; let value: Double }
    }
    static func merged(_ values: [(id: String, value: Double)]) -> Merged {
        var seen = Set<String>()
        let sorted = values.filter { $0.value.isFinite && $0.value > 0 && seen.insert($0.id).inserted }
            .sorted { $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value }
            .map { Merged.Entry(id: $0.id, value: $0.value) }
        guard sorted.count > maximumBubbles else { return Merged(values: sorted, mergedIDs: []) }
        let kept = Array(sorted.prefix(maximumBubbles - 1))
        let tail = sorted.dropFirst(maximumBubbles - 1)
        let total = tail.reduce(0.0) { $0 + $1.value }
        return Merged(values: kept + [.init(id: otherID, value: total.isFinite ? total : Double.greatestFiniteMagnitude)],
                      mergedIDs: tail.map(\.id))
    }

    /// Largest stays exactly at the viewport center. Above the 14 pt minimum,
    /// radii are sqrt(value) with one global scale, so area ratios hold; the
    /// minimum is solved by re-packing (it changes the scale) until it holds or
    /// the field is too small for it. Hover envelopes are reserved; never random.
    static func placements(values: [(id: String, value: Double)], size: CGSize) -> [LightfieldBubblePlacement] {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return [] }
        // A merged tail can outweigh every individual entry (e.g. equal
        // values). Normalize and center using the largest displayed bubble.
        let entries = merged(values).values
            .sorted { $0.value == $1.value ? $0.id < $1.id : $0.value > $1.value }
        guard let largest = entries.first?.value else { return [] }
        func layout(minimum: CGFloat) -> (placements: [LightfieldBubblePlacement], scale: CGFloat) {
            let radii = entries.map { max(minimum, CGFloat(sqrt($0.value / largest))) }
            let (placed, scale) = pack(ids: entries.map(\.id), radii: radii, size: size)
            return (placed.map { .init(id: $0.id,
                center: CGPoint(x: size.width / 2 + $0.center.x * scale, y: size.height / 2 + $0.center.y * scale),
                radius: $0.radius * scale) }, scale)
        }
        let proportional = layout(minimum: 0)
        let smallest = entries.map { CGFloat(sqrt($0.value / largest)) }.min() ?? 1
        guard smallest * proportional.scale < minimumRadius - 0.01 else { return proportional.placements }
        // Raising small radii shrinks the scale, so iterate to the fixed point
        // (slight overshoot converges in a few passes).
        var minimum = minimumRadius / proportional.scale
        for _ in 0..<24 where minimum < 1 {
            let attempt = layout(minimum: minimum)
            if minimum * attempt.scale >= minimumRadius - 0.01 { return attempt.placements }
            minimum = minimumRadius / attempt.scale * 1.02
        }
        // The field cannot hold every bubble at 14 pt: keep true area ratios.
        return proportional.placements
    }

    /// Normalized packing (largest radius 1 at the origin) and the scale that
    /// fits the envelopes into `size`, capped at the 180 pt maximum diameter.
    private static func pack(ids: [String], radii: [CGFloat], size: CGSize) -> ([LightfieldBubblePlacement], CGFloat) {
        var placed = [LightfieldBubblePlacement(id: ids[0], center: .zero, radius: radii[0])]
        var extent = CGSize(width: radii[0] * hoverScale, height: radii[0] * hoverScale)
        for (id, radius) in zip(ids.dropFirst(), radii.dropFirst()) {
            var best: CGPoint?
            var bestFit = CGFloat.infinity
            var bestDistance = CGFloat.infinity
            for anchor in placed {
                let distance = (anchor.radius + radius) * hoverScale + gap
                for angleIndex in 0..<72 {
                    let angle = CGFloat(angleIndex) * .pi / 36 - .pi / 2
                    let candidate = CGPoint(x: anchor.center.x + cos(angle) * distance,
                                            y: anchor.center.y + sin(angle) * distance)
                    guard placed.allSatisfy({ other in
                        hypot(candidate.x - other.center.x, candidate.y - other.center.y) + 1e-9
                            >= (radius + other.radius) * hoverScale + gap - 0.001
                    }) else { continue }
                    // Prefer the candidate that keeps the cluster's aspect closest to
                    // the field (largest final scale), then the most compact one.
                    let fit = max(max(extent.width, abs(candidate.x) + radius * hoverScale) / size.width,
                                  max(extent.height, abs(candidate.y) + radius * hoverScale) / size.height)
                    let score = hypot(candidate.x, candidate.y)
                    if fit < bestFit - 1e-9 || (abs(fit - bestFit) <= 1e-9 && score < bestDistance) {
                        best = candidate; bestFit = fit; bestDistance = score
                    }
                }
            }
            // A deterministic ray beyond the rightmost envelope is always
            // feasible, including long lists with tiny or equal values.
            let right = placed.map { $0.center.x + $0.radius * hoverScale }.max() ?? 0
            let center = best ?? CGPoint(x: right + radius * hoverScale + gap, y: 0)
            placed.append(.init(id: id, center: center, radius: radius))
            extent = CGSize(width: max(extent.width, abs(center.x) + radius * hoverScale),
                            height: max(extent.height, abs(center.y) + radius * hoverScale))
        }
        let scale = min(size.width / (2 * extent.width), size.height / (2 * extent.height), maximumDiameter / 2)
        return (placed, scale)
    }
}

/// B2 review P2-3: layouts are cached by (values, size); hover never re-packs.
@MainActor final class LightfieldBubbleLayoutCache {
    private struct Key: Equatable { let values: [LightfieldBubbleLayout.Merged.Entry]; let size: CGSize }
    private var key: Key?
    private var cached: [LightfieldBubblePlacement] = []
    private(set) var computeCount = 0
    func placements(values: [(id: String, value: Double)], size: CGSize) -> [LightfieldBubblePlacement] {
        let next = Key(values: values.map { .init(id: $0.id, value: $0.value.isFinite ? $0.value : -1) }, size: size)
        if next != key {
            key = next
            cached = LightfieldBubbleLayout.placements(values: values, size: size)
            computeCount += 1
        }
        return cached
    }
}

struct LightfieldDonutArc: Equatable {
    let id: String
    let start: Double
    let end: Double
    var fraction: Double { end - start }
}
enum LightfieldDonutGeometry {
    static let diameter: CGFloat = 132
    static let lineWidth: CGFloat = 14
    static func arcs(values: [(id: String, value: Double)]) -> [LightfieldDonutArc] {
        let positive = values.filter { $0.value.isFinite && $0.value > 0 }
        let largest = positive.map { $0.value }.max() ?? 1
        let total = positive.reduce(0) { $0 + $1.value / largest }
        guard total > 0 else { return [] }
        var start = 0.0
        return positive.map { item in
            let end = min(1, start + item.value / largest / total)
            defer { start = end }
            return .init(id: item.id, start: start, end: end)
        }
    }
}
