import SwiftUI

struct MenuBarTelemetrySeries: Identifiable {
    let id: String
    let title: String
    let channel: MenuBarTelemetryChannel
    let color: Color
    let dash: [CGFloat]

    init(
        id: String,
        title: String,
        channel: MenuBarTelemetryChannel,
        color: Color,
        dash: [CGFloat] = []
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.color = color
        self.dash = dash
    }
}

struct MenuBarChartSample: Equatable {
    let date: Date
    let value: Double?
}

enum MenuBarChartGeometry {
    static func niceCeiling(for values: [Double], minimum: Double = 1) -> Double {
        guard let rawMaximum = values.filter(\.isFinite).max(), rawMaximum > 0 else {
            return minimum
        }

        let target = max(minimum, rawMaximum * 1.08)
        let magnitude = pow(10, floor(log10(target)))
        let fraction = target / magnitude
        let niceFraction = [1.0, 1.25, 1.5, 2, 2.5, 5, 7.5, 10]
            .first(where: { fraction <= $0 }) ?? 10
        return max(minimum, niceFraction * magnitude)
    }

    static func pointSegments(
        samples: [MenuBarChartSample],
        size: CGSize,
        valueRange: ClosedRange<Double>,
        verticalPadding: CGFloat = 3
    ) -> [[CGPoint]] {
        guard !samples.isEmpty, size.width > 0, size.height > 0 else {
            return []
        }

        let dates = samples.map(\.date)
        let firstDate = dates.first ?? .distantPast
        let lastDate = dates.last ?? firstDate
        let duration = lastDate.timeIntervalSince(firstDate)
        let usableHeight = max(1, size.height - verticalPadding * 2)
        let valueSpan = max(Double.ulpOfOne, valueRange.upperBound - valueRange.lowerBound)
        let gapThreshold = PanelChartSampling.samplingGapThreshold(for: dates)

        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        var previousValidDate: Date?

        func finishCurrentSegment() {
            guard !current.isEmpty else { return }
            result.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for sample in samples {
            guard let rawValue = sample.value, rawValue.isFinite else {
                finishCurrentSegment()
                previousValidDate = nil
                continue
            }

            if let previousValidDate,
               sample.date.timeIntervalSince(previousValidDate) > gapThreshold {
                finishCurrentSegment()
            }

            let x: CGFloat
            if duration > 0 {
                x = size.width * CGFloat(sample.date.timeIntervalSince(firstDate) / duration)
            } else {
                x = size.width
            }
            let value = min(valueRange.upperBound, max(valueRange.lowerBound, rawValue))
            let normalized = (value - valueRange.lowerBound) / valueSpan
            let y = verticalPadding + usableHeight * CGFloat(1 - normalized)
            current.append(CGPoint(x: x, y: y))
            previousValidDate = sample.date
        }

        finishCurrentSegment()
        return result
    }

    static func smoothedPath(for segments: [[CGPoint]]) -> Path {
        var path = Path()
        for points in segments {
            appendSmoothedLine(points, to: &path)
        }
        return path
    }

    static func areaPath(for segments: [[CGPoint]], baseline: CGFloat) -> Path {
        var path = Path()
        for points in segments where !points.isEmpty {
            guard let first = points.first, let last = points.last else { continue }
            path.move(to: CGPoint(x: first.x, y: baseline))
            path.addLine(to: first)
            appendSmoothedLine(Array(points.dropFirst()), previousPoint: first, to: &path)
            path.addLine(to: CGPoint(x: last.x, y: baseline))
            path.closeSubpath()
        }
        return path
    }

    private static func appendSmoothedLine(_ points: [CGPoint], to path: inout Path) {
        guard let first = points.first else { return }
        path.move(to: first)
        appendSmoothedLine(Array(points.dropFirst()), previousPoint: first, to: &path)
    }

    private static func appendSmoothedLine(
        _ remainingPoints: [CGPoint],
        previousPoint first: CGPoint,
        to path: inout Path
    ) {
        guard !remainingPoints.isEmpty else { return }
        let points = [first] + remainingPoints
        guard points.count > 2 else {
            for point in remainingPoints {
                path.addLine(to: point)
            }
            return
        }

        for index in 0..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let previous = index > 0 ? points[index - 1] : current
            let following = index + 2 < points.count ? points[index + 2] : next
            let lowerY = min(current.y, next.y)
            let upperY = max(current.y, next.y)

            let control1 = CGPoint(
                x: min(next.x, max(current.x, current.x + (next.x - previous.x) / 6)),
                y: min(upperY, max(lowerY, current.y + (next.y - previous.y) / 6))
            )
            let control2 = CGPoint(
                x: min(next.x, max(current.x, next.x - (following.x - current.x) / 6)),
                y: min(upperY, max(lowerY, next.y - (following.y - current.y) / 6))
            )
            path.addCurve(to: next, control1: control1, control2: control2)
        }
    }
}


enum MenuBarNetworkPalette {
    static let download = AppChartPalette.download
    static let upload = AppChartPalette.upload
}
