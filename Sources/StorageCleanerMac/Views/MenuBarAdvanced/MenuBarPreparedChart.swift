import SwiftUI

struct MenuBarChartContext: Equatable {
    let page: String
    let revision: MenuBarDisplayRevision
}
private struct MenuBarChartContextKey: EnvironmentKey {
    static let defaultValue: MenuBarChartContext? = nil
}
extension EnvironmentValues {
    var menuBarChartContext: MenuBarChartContext? {
        get { self[MenuBarChartContextKey.self] }
        set { self[MenuBarChartContextKey.self] = newValue }
    }
}

@MainActor
final class MenuBarPreparedChartModel<Value: Sendable>: ObservableObject {
    @Published private(set) var value: Value?
    private var desiredKey: MenuBarDerivedKey?
    private var deliveredKey: MenuBarDerivedKey?
    private var pending: (MenuBarDerivedKey, Int, @Sendable () -> Value)?
    private var worker: Task<Void, Never>?
    private var generation = 0
    let cache: MenuBarDerivedCache

    init(cache: MenuBarDerivedCache = .shared) { self.cache = cache }

    func request(key: MenuBarDerivedKey, cost: Int, build: @escaping @Sendable () -> Value) {
        desiredKey = key
        guard deliveredKey != key || value == nil else { pending = nil; return }
        if let deliveredKey, deliveredKey.family != key.family { value = nil }
        pending = (key, cost, build)
        guard worker == nil else { return }
        let capturedGeneration = generation
        worker = Task { @MainActor [weak self] in
            while let self, let request = pending {
                pending = nil
                let prepared = await cache.value(for: request.0, cost: request.1, build: request.2)
                guard !Task.isCancelled, generation == capturedGeneration else { return }
                if desiredKey == request.0 {
                    deliveredKey = request.0
                    value = prepared
                    pending = nil
                }
            }
            self?.worker = nil
        }
    }

    func stop() {
        generation &+= 1
        pending = nil
        desiredKey = nil
        worker?.cancel()
        worker = nil
    }
}

struct MenuBarPreparedChart<Value: Sendable, Content: View>: View {
    let key: MenuBarDerivedKey
    let cost: Int
    let build: @Sendable () -> Value
    @ViewBuilder let content: (Value) -> Content
    @StateObject private var model = MenuBarPreparedChartModel<Value>()

    var body: some View {
        Group {
            if let value = model.value { content(value) }
            else { Color.clear.accessibilityLabel(PanelChartSampling.statusText) }
        }
        .task(id: key) { model.request(key: key, cost: cost, build: build) }
        .onDisappear { model.stop() }
    }
}

extension MenuBarChartContext {
    func key(kind: String, first: Date?, last: Date?, count: Int, clockRevision: TimeInterval = 0, configuration: String) -> MenuBarDerivedKey {
        MenuBarDerivedKey(page: page, kind: kind,
                          revision: "\(revision.sampledAt?.timeIntervalSince1970 ?? 0):\(revision.version):\(first?.timeIntervalSince1970 ?? 0):\(last?.timeIntervalSince1970 ?? 0):\(count):\(clockRevision)",
                          configuration: configuration)
    }
}

/// Static previews outside the live panel retain synchronous rendering. Every
/// live panel and attached history provides a context and uses the worker path.
struct MenuBarChartPreparation<Value: Sendable, Content: View>: View {
    @Environment(\.menuBarChartContext) private var context
    let kind: String
    let first: Date?
    let last: Date?
    let count: Int
    let configuration: String
    var clockRevision: TimeInterval = 0
    let cost: Int
    let build: @Sendable () -> Value
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        if let context {
            MenuBarPreparedChart(key: context.key(kind: kind, first: first, last: last, count: count, clockRevision: clockRevision,
                                                  configuration: configuration),
                                 cost: cost, build: build, content: content)
        } else {
            content(build())
        }
    }
}

struct GeekPreparedLineSummary: Sendable {
    let channels: [MenuBarTelemetryChannel]
    let statistics: [MenuBarTelemetryChannel: GeekSeriesStatistics]

    init(points: [MenuBarTelemetryPoint], channels: [MenuBarTelemetryChannel]) {
        var visible: [MenuBarTelemetryChannel] = []
        var stats: [MenuBarTelemetryChannel: GeekSeriesStatistics] = [:]
        for channel in channels {
            let samples = points.map { MenuBarChartSample(date: $0.date, value: channel.value(in: $0)) }
            if PanelChartSampling.hasRenderableTrend(samples) { visible.append(channel) }
            stats[channel] = GeekSeriesStatistics(values: samples.compactMap(\.value))
        }
        self.channels = visible
        statistics = stats
    }
}

struct GeekPreparedLineFrame: Sendable {
    let sourcePoints: [MenuBarTelemetryPoint]
    let cpu: GeekCPUHistoryFrame?
    let buckets: [GeekChartBucketSnapshot]
    let values: [[Double?]]
    let hoverValues: [[Double?]]
    let hoverEstimated: [[Bool]]
    let segments: [MenuBarTelemetryChannel: [[CGPoint]]]
    let range: (start: Date, end: Date, dataStart: Date)

    init(points: [MenuBarTelemetryPoint], channels: [MenuBarTelemetryChannel],
         plot: CGRect, duration: TimeInterval, reference: Date, samplingInterval: TimeInterval,
         scale: CGFloat, stacked: Bool, valueRange: ClosedRange<Double>) {
        sourcePoints = points
        let dates = points.map(\.date)
        if stacked { range = GeekChartWindow.barRange(for: dates, duration: duration, referenceDate: reference) }
        else {
            let window = GeekChartWindow.range(for: dates, duration: duration, referenceDate: reference)
            range = (window.start, window.end, dates.first ?? window.start)
        }
        let bucketRange = GeekChartWindow.barRange(for: dates, duration: duration, referenceDate: reference)
        let usesCPU = stacked && !channels.isEmpty && channels.allSatisfy { [.cpuTotal, .cpuUser, .cpuSystem].contains($0) }
        cpu = usesCPU ? GeekCPUHistoryFrame.prepare(points: points, plotRect: plot, duration: duration,
                                                    referenceDate: reference, samplingInterval: samplingInterval,
                                                    displayScale: scale) : nil
        if stacked || GeekHistoryAveraging.interval(for: duration) != nil {
            buckets = GeekChartWindow.displayBuckets(for: dates, in: plot, range: bucketRange,
                referenceDate: reference, displayScale: scale,
                isValid: { index in channels.allSatisfy { $0.value(in: points[index])?.isFinite == true } },
                isMissing: { index in stacked && channels.allSatisfy { $0.value(in: points[index]) == nil } },
                holdLatestWhileFresh: true)
        } else {
            buckets = GeekChartWindow.barBucketSnapshots(for: dates, in: plot, range: bucketRange,
                referenceDate: reference, displayScale: scale)
        }
        values = buckets.map { bucket in channels.map { channel in
            bucket.displayValue { index in
                if stacked && !channels.allSatisfy({ $0.value(in: points[index])?.isFinite == true }) { return nil }
                return channel.value(in: points[index])
            }
        } }
        let values = self.values
        let bucketValues = self.buckets
        let filled = channels.indices.map { channel in
            TimeBucketAggregator.nearestFilled(values.map { $0[channel] })
        }
        hoverValues = bucketValues.indices.map { index in channels.indices.map { channel in
            bucketValues[index].averagingGroups != nil ? values[index][channel] : filled[channel][index].value
        } }
        hoverEstimated = bucketValues.indices.map { index in channels.indices.map { channel in
            bucketValues[index].averagingGroups == nil && (bucketValues[index].isEstimated || filled[channel][index].isEstimated)
        } }
        let buckets = self.buckets
        var paths: [MenuBarTelemetryChannel: [[CGPoint]]] = [:]
        if !stacked {
            let span = max(Double.ulpOfOne, valueRange.upperBound - valueRange.lowerBound)
            for channel in channels {
                let filled = TimeBucketAggregator.nearestFilled(buckets.map { bucket in
                    bucket.displayValue { channel.value(in: points[$0]) }
                })
                paths[channel] = TimeBucketAggregator.observedSegments(filled.map(\.value), in: buckets,
                    sampleDates: dates, isSampleValid: { channel.value(in: points[$0])?.isFinite == true }).map { segment in
                    segment.map { sample in
                        let value = min(valueRange.upperBound, max(valueRange.lowerBound, sample.value))
                        return CGPoint(x: buckets[sample.index].x,
                                       y: plot.minY + 2 + max(1, plot.height - 4) * CGFloat(1 - (value - valueRange.lowerBound) / span))
                    }
                }
            }
        }
        segments = paths
    }
}

struct GeekPreparedDiskSummary: Sendable {
    let hasData: Bool
    let read: GeekSeriesStatistics?
    let write: GeekSeriesStatistics?
    init(points allPoints: [NativeDiskIOPoint], duration: TimeInterval = GeekChartWindow.defaultDuration) {
        let points = MenuBarHistoryRetention.selected(allPoints, duration: duration, date: \.date, referenceDate: allPoints.last?.date ?? Date())
        hasData = PanelChartSampling.hasRenderableTrend(points.map {
            MenuBarChartSample(date: $0.date, value: Double($0.readBytesPerSecond))
        })
        read = GeekSeriesStatistics(values: points.map { Double($0.readBytesPerSecond) })
        write = GeekSeriesStatistics(values: points.map { Double($0.writeBytesPerSecond) })
    }
}

struct GeekPreparedDiskFrame: Sendable {
    let buckets: [GeekChartBucketSnapshot]
    let reads: [Double?]
    let writes: [Double?]
    let readMarks: [GeekMirroredBarMark]
    let writeMarks: [GeekMirroredBarMark]
    let maximum: Double
    let range: (start: Date, end: Date, dataStart: Date)
    init(points allPoints: [NativeDiskIOPoint], plot: CGRect, duration: TimeInterval, reference: Date, scale: CGFloat) {
        let points = MenuBarHistoryRetention.selected(allPoints, duration: duration, date: \.date, referenceDate: reference)
        let dates = points.map(\.date)
        let window = GeekChartWindow.barRange(for: dates, duration: duration, referenceDate: reference)
        range = window
        let buckets = GeekChartWindow.displayBuckets(for: dates, in: plot, range: window,
            referenceDate: reference, displayScale: scale,
            intervalStart: { points[$0].intervalStart }, holdLatestWhileFresh: true)
        self.buckets = buckets
        let reads = buckets.map { $0.displayValue { Double(points[$0].readBytesPerSecond) } }
        let writes = buckets.map { $0.displayValue { Double(points[$0].writeBytesPerSecond) } }
        self.reads = reads
        self.writes = writes
        maximum = GeekBarChartScale.throughputUpperBound(for: (reads + writes).compactMap { $0 })
        func marks(_ values: [Double?]) -> [GeekMirroredBarMark] {
            zip(buckets, TimeBucketAggregator.nearestFilled(values)).compactMap { bucket, value in
                value.value.map { GeekMirroredBarMark(x: bucket.x, value: $0,
                    isEstimated: bucket.isEstimated || value.isEstimated) }
            }
        }
        readMarks = marks(reads)
        writeMarks = marks(writes)
    }
}
