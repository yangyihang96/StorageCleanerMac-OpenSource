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
    /// `value` is the frame of another window of the same chart (kept while
    /// the requested window's frame is built, see `request`). The history
    /// shows "更新中…" meanwhile (`GeekHistoryPreviousFrameKey`).
    @Published private(set) var isShowingPreviousValue = false
    private var desiredKey: MenuBarDerivedKey?
    private var deliveredKey: MenuBarDerivedKey?
    private var deliveredShape: String?
    private var deliveredWindow: TimeInterval?
    private var pending: (key: MenuBarDerivedKey, shape: String?, window: TimeInterval?, cost: Int,
                          build: @Sendable () -> Value)?
    private var worker: Task<Void, Never>?
    private var generation = 0
    let cache: MenuBarDerivedCache

    init(cache: MenuBarDerivedCache = .shared) { self.cache = cache }

    /// `shape` names what must stay equal for the delivered value to remain
    /// on screen while a value of another configuration is prepared: a
    /// chart's series and plot geometry, but not its time window. Switching
    /// only the window then keeps the previous frame until the new one is
    /// ready. Without a shape, or when the shape changes, a value of another
    /// configuration is cleared at once, because it would be drawn in the
    /// wrong place.
    func request(key: MenuBarDerivedKey, shape: String? = nil, window: TimeInterval? = nil, cost: Int,
                 build: @escaping @Sendable () -> Value) {
        desiredKey = key
        guard deliveredKey != key || value == nil else {
            pending = nil
            if isShowingPreviousValue { isShowingPreviousValue = false }
            return
        }
        if let deliveredKey, deliveredKey.family != key.family,
           shape == nil || shape != deliveredShape {
            value = nil
        }
        // "Previous" means another time window (BOARD N11-1). A request that
        // names its window is compared by window only: a new value range or
        // sampling interval of the same window changes the key, not the
        // window the frame on screen shows.
        let showsAnotherWindow: Bool
        if let window, let deliveredWindow {
            showsAnotherWindow = window != deliveredWindow
        } else {
            showsAnotherWindow = deliveredKey.map { $0.family != key.family } == true
        }
        let showsPrevious = value != nil && showsAnotherWindow
        if isShowingPreviousValue != showsPrevious { isShowingPreviousValue = showsPrevious }
        pending = (key, shape, window, cost, build)
        guard worker == nil else { return }
        let capturedGeneration = generation
        worker = Task { @MainActor [weak self] in
            while let self, let request = pending {
                pending = nil
                let prepared = await cache.value(for: request.key, cost: request.cost, build: request.build)
                guard !Task.isCancelled, generation == capturedGeneration else { return }
                if desiredKey == request.key {
                    deliveredKey = request.key
                    deliveredShape = request.shape
                    deliveredWindow = request.window
                    value = prepared
                    if isShowingPreviousValue { isShowingPreviousValue = false }
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

    /// Audit only: whether the drawn value was prepared for `key`.
    func isDelivered(_ key: MenuBarDerivedKey) -> Bool { value != nil && deliveredKey == key }
}

struct MenuBarPreparedChart<Value: Sendable, Content: View>: View {
    let key: MenuBarDerivedKey
    var shape: String? = nil
    /// The time window the frame shows (`MenuBarPreparedChartModel.request`).
    var window: TimeInterval? = nil
    let cost: Int
    let build: @Sendable () -> Value
    var placeholder: AnyView? = nil
    /// Audit only: the prepared input has samples.
    var hasData = true
    @ViewBuilder let content: (Value) -> Content
    @StateObject private var model = MenuBarPreparedChartModel<Value>()

    var body: some View {
        Group {
            if let value = model.value { content(value) }
            else if let placeholder { placeholder.accessibilityLabel(PanelChartSampling.statusText) }
            else { Color.clear.accessibilityLabel(PanelChartSampling.statusText) }
        }
        .menuBarTraceProbe {
            // A plotted frame of the requested data; summaries and stand-in
            // frames of another window do not acknowledge.
            if key.kind.hasSuffix("-frame") {
                MenuBarPreparedChartProbe(
                    revision: MenuBarPresentationProbe.revision(key.revision + key.configuration),
                    isDelivered: model.isDelivered(key),
                    hasData: hasData
                )
            }
        }
        .preference(key: GeekHistoryPreviousFrameKey.self, value: model.isShowingPreviousValue)
        .task(id: key) { model.request(key: key, shape: shape, window: window, cost: cost, build: build) }
        .onDisappear { model.stop() }
    }
}

/// `chart.<region>`: the first draw of a frame prepared for the requested
/// data, unless the history still shows the previously selected window.
/// `chart.empty.<region>`: a frame prepared from no samples was drawn.
private struct MenuBarPreparedChartProbe: View {
    @Environment(\.menuBarTraceRegion) private var region
    @Environment(\.menuBarTraceChartIsStale) private var isStale
    let revision: UInt64
    let isDelivered: Bool
    let hasData: Bool

    var body: some View {
        if isDelivered, !isStale {
            MenuBarPresentationProbe(key: hasData ? "chart.\(region)" : "chart.empty.\(region)", revision: revision)
                .frame(width: 1, height: 1)
        }
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
#if DEBUG
private struct MenuBarChartsPreparedInlineKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Offscreen page tests (D119): build every chart in the body.
    /// `ImageRenderer` draws once, before a chart's preparation task can
    /// deliver, so a prepared chart would stay at its placeholder.
    var menuBarChartsPreparedInline: Bool {
        get { self[MenuBarChartsPreparedInlineKey.self] }
        set { self[MenuBarChartsPreparedInlineKey.self] = newValue }
    }
}
#endif

struct MenuBarChartPreparation<Value: Sendable, Content: View>: View {
    @Environment(\.menuBarChartContext) private var context
#if DEBUG
    @Environment(\.menuBarChartsPreparedInline) private var preparesInline
#endif
    let kind: String
    let first: Date?
    let last: Date?
    let count: Int
    let configuration: String
    /// See `MenuBarPreparedChartModel.request`: the part of the configuration
    /// that is not the time window. Values of one shape stand in for each
    /// other while the window changes.
    var shape: String? = nil
    /// The time window shown; with it, only another window marks the frame
    /// on screen as the previous one ("更新中…").
    var window: TimeInterval? = nil
    var clockRevision: TimeInterval = 0
    let cost: Int
    let build: @Sendable () -> Value
    var placeholder: AnyView? = nil
    @ViewBuilder let content: (Value) -> Content

    private var preparedContext: MenuBarChartContext? {
#if DEBUG
        if preparesInline { return nil }
#endif
        return context
    }

    var body: some View {
        if let context = preparedContext {
            MenuBarPreparedChart(key: context.key(kind: kind, first: first, last: last, count: count, clockRevision: clockRevision,
                                                  configuration: configuration),
                                 shape: shape, window: window,
                                 cost: cost, build: build, placeholder: placeholder, hasData: count > 0, content: content)
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
            let samples = MenuBarTelemetryPoint.historyPoints(points, channels: [channel]).map {
                MenuBarChartSample(date: $0.date, value: channel.value(in: $0))
            }
            if PanelChartSampling.hasRenderableTrend(samples) || GeekCompressedHistoryProjection.hasTrend(points, channel: channel) { visible.append(channel) }
            stats[channel] = GeekCompressedHistoryProjection.telemetryStatistics(points, channel: channel)
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
    /// Per bucket, the most severe memory-pressure level among its samples;
    /// prepared only for the memory-pressure channel.
    let pressureLevels: [MemoryPressureLevel?]

    /// `unrecordedIntervals` nil reads the shared known pauses, as every chart
    /// does. A caller that owns its pauses (a test fixture) passes them here,
    /// and every step of this frame then uses that list instead.
    /// D130, D131: `bucketing` picks iStat's history buckets (level three) or
    /// one bar per sample (levels one and two); neither estimates a missing
    /// bucket, and the history weights a folded minute by its sample count.
    init(points: [MenuBarTelemetryPoint], channels: [MenuBarTelemetryChannel],
         plot: CGRect, duration: TimeInterval, reference: Date, samplingInterval: TimeInterval,
         scale: CGFloat, stacked: Bool, valueRange: ClosedRange<Double>,
         unrecordedIntervals: [DateInterval]? = nil, bucketing: GeekChartBucketing = .projection) {
        let points = MenuBarTelemetryPoint.historyPoints(points, channels: channels)
        sourcePoints = points
        let dates = points.map(\.date)
        let bucketRange = GeekChartWindow.barRange(for: dates, duration: duration, referenceDate: reference)
        let averagingInterval = bucketing == .projection ? GeekHistoryAveraging.interval(for: duration) : nil
        let usesCPU = stacked && !channels.isEmpty && channels.allSatisfy { [.cpuTotal, .cpuUser, .cpuSystem].contains($0) }
        var preparedBuckets: [GeekChartBucketSnapshot]
        switch bucketing {
        case .samples:
            preparedBuckets = GeekIStatSampleBars.buckets(dates: dates, plotRect: plot, displayScale: scale,
                referenceDate: reference, isSample: { index in
                    points[index].bucketStatistics == nil && channels.contains { $0.value(in: points[index]) != nil }
                })
            range = GeekIStatHistoryBuckets.range(of: preparedBuckets.filter { !$0.indices.isEmpty }, fallback: reference)
        case .history:
            let gaps = unrecordedIntervals ?? MenuBarSamplingGaps.shared.intervals(at: reference)
            preparedBuckets = GeekIStatHistoryBuckets.buckets(dates: dates,
                interval: GeekIStatHistoryBuckets.interval(for: duration), plotRect: plot,
                referenceDate: reference, displayScale: scale, gaps: gaps,
                isMissing: { index in
                    usesCPU ? !GeekCPUHistoryFrame.isComplete(points[index])
                        : channels.allSatisfy { $0.mean(in: points[index]) == nil }
                },
                weight: { index in
                    Double(max(1, channels.first.flatMap { points[index].bucketStatistics?.metrics[$0.rawValue]?.sampleCount } ?? 1))
                })
            range = GeekIStatHistoryBuckets.range(of: preparedBuckets, fallback: reference)
        case .projection:
            if stacked { range = bucketRange }
            else {
                let window = GeekChartWindow.range(for: dates, duration: duration, referenceDate: reference)
                range = (window.start, window.end, dates.first ?? window.start)
            }
            if stacked || averagingInterval != nil {
                preparedBuckets = GeekChartWindow.displayBuckets(for: dates, in: plot, range: bucketRange,
                    referenceDate: reference, displayScale: scale,
                    isValid: { index in channels.allSatisfy { $0.value(in: points[index])?.isFinite == true } },
                    isMissing: { index in
                        if usesCPU, averagingInterval != nil {
                            return !GeekCPUHistoryFrame.isComplete(points[index])
                        }
                        return stacked && channels.allSatisfy { $0.value(in: points[index]) == nil }
                    },
                    unrecordedIntervals: unrecordedIntervals,
                    holdLatestWhileFresh: true)
            } else {
                preparedBuckets = GeekChartWindow.barBucketSnapshots(for: dates, in: plot, range: bucketRange,
                    referenceDate: reference, displayScale: scale)
            }
        }
        let compressed = bucketing == .projection && points.contains { $0.bucketStatistics != nil }
        if compressed, let channel = channels.first {
            let gaps = unrecordedIntervals ?? MenuBarSamplingGaps.shared.intervals(at: reference)
            preparedBuckets = GeekCompressedHistoryProjection.buckets(preparedBuckets, dates: dates,
                records: points.indices.map { points[$0].statistic(for: channel, previous: $0 > 0 ? points[$0 - 1] : nil, gaps: gaps) })
        }
        buckets = preparedBuckets
        cpu = usesCPU && bucketing == .projection ? GeekCPUHistoryFrame.prepare(points: points, plotRect: plot, duration: duration,
                                                    referenceDate: reference, samplingInterval: samplingInterval,
                                                    displayScale: scale,
                                                    preparedAveragedBuckets: averagingInterval == nil ? nil : buckets,
                                                    unrecordedIntervals: unrecordedIntervals) : nil
        if let cpu, averagingInterval != nil {
            let means = Dictionary(uniqueKeysWithValues: cpu.marks.map { ($0.bucket.x, $0.mean) })
            values = buckets.map { bucket in
                channels.map { channel in means[bucket.x].flatMap { channel.value(in: $0) } }
            }
        } else {
            values = buckets.map { bucket in channels.map { channel in
                bucket.displayValue { index in
                    if stacked && !channels.allSatisfy({ $0.value(in: points[index])?.isFinite == true }) { return nil }
                    return channel.mean(in: points[index])
                }
            } }
        }
        let values = self.values
        let bucketValues = self.buckets
        let filled = channels.indices.map { channel in
            TimeBucketAggregator.nearestFilled(values.map { $0[channel] })
        }
        // D130: iStat's tooltip shows a bucket's mean, never an estimate.
        let estimates = bucketing == .projection
        hoverValues = bucketValues.indices.map { index in channels.indices.map { channel in
            !estimates || bucketValues[index].averagingGroups != nil ? values[index][channel] : filled[channel][index].value
        } }
        hoverEstimated = bucketValues.indices.map { index in channels.indices.map { channel in
            estimates && bucketValues[index].averagingGroups == nil
                && (bucketValues[index].isEstimated || filled[channel][index].isEstimated)
        } }
        let buckets = self.buckets
        var paths: [MenuBarTelemetryChannel: [[CGPoint]]] = [:]
        if !stacked {
            let span = max(Double.ulpOfOne, valueRange.upperBound - valueRange.lowerBound)
            for channel in channels {
                let observedValues = buckets.map { bucket in
                    bucket.displayValue { channel.mean(in: points[$0]) }
                }
                let filled = compressed || !estimates
                    ? observedValues.enumerated().map { TimeBucketValue(value: $0.element, isEstimated: false, sourceIndex: $0.offset) }
                    : TimeBucketAggregator.nearestFilled(observedValues)
                paths[channel] = TimeBucketAggregator.observedSegments(filled.map(\.value), in: buckets,
                    sampleDates: dates, unrecordedIntervals: unrecordedIntervals,
                    isSampleValid: { channel.value(in: points[$0])?.isFinite == true }).map { segment in
                    segment.map { sample in
                        let value = min(valueRange.upperBound, max(valueRange.lowerBound, sample.value))
                        return CGPoint(x: buckets[sample.index].x,
                                       y: plot.minY + 2 + max(1, plot.height - 4) * CGFloat(1 - (value - valueRange.lowerBound) / span))
                    }
                }
            }
        }
        segments = paths
        pressureLevels = channels.contains(.memoryPressure)
            ? buckets.map { bucket in
                bucket.indices
                    .compactMap { points.indices.contains($0) ? points[$0].memoryPressureLevel : nil }
                    .max { $0.severity < $1.severity }
            }
            : []
    }
}

struct GeekPreparedDiskSummary: Sendable {
    static let preparationKind = "disk-summary"
    static func preparationConfiguration(duration: TimeInterval) -> String { "disk:\(duration)" }
    /// One shape for every window: a summary of the previous window stays
    /// until the selected window's summary is ready.
    static let preparationShape = "disk"
    let referenceDate: Date
    let hasData: Bool
    let read: GeekSeriesStatistics?
    let write: GeekSeriesStatistics?
    let readPeakBytesPerSecond: Int64?
    let writePeakBytesPerSecond: Int64?
    /// D128: iStat's disk activity rows (`format:label:alignment:`).
    var readPeakText: String { readPeakBytesPerSecond.map { IStatNumberFormat.diskActivity($0) } ?? "--" }
    var writePeakText: String { writePeakBytesPerSecond.map { IStatNumberFormat.diskActivity($0) } ?? "--" }
    init(points allPoints: [NativeDiskIOPoint], duration: TimeInterval = GeekChartWindow.defaultDuration, referenceDate: Date) {
        self.referenceDate = referenceDate
        let points = MenuBarHistoryRetention.selected(allPoints, duration: duration, date: \.date, referenceDate: referenceDate)
        hasData = PanelChartSampling.hasRenderableTrend(points.map {
            MenuBarChartSample(date: $0.date, value: Double($0.readBytesPerSecond))
        }) || points.contains { ($0.bucketStatistics?.metrics["diskRead"]?.sampleCount ?? 0) >= 2
            && ($0.bucketStatistics?.metrics["diskRead"]?.coveredDuration ?? 0) > 0 }
        let gaps = MenuBarSamplingGaps.shared.intervals(at: referenceDate)
        let records = points.indices.map { points[$0].statistics(previous: $0 > 0 ? points[$0 - 1] : nil, gaps: gaps) }
        read = GeekSeriesStatistics(records: records.compactMap { $0.metrics["diskRead"] }, current: points.last.map { Double($0.readBytesPerSecond) })
        write = GeekSeriesStatistics(records: records.compactMap { $0.metrics["diskWrite"] }, current: points.last.map { Double($0.writeBytesPerSecond) })
        readPeakBytesPerSecond = read.map { Int64(clampingHistoryValue: $0.maximum) }
        writePeakBytesPerSecond = write.map { Int64(clampingHistoryValue: $0.maximum) }
    }
}

struct GeekPreparedDiskFrame: Sendable {
    let buckets: [GeekChartBucketSnapshot]
    let reads: [Double?]
    let writes: [Double?]
    let readMarks: [GeekMirroredBarMark]
    let writeMarks: [GeekMirroredBarMark]
    /// Scale of the read series and of the write series (D117).
    let readMaximum: Double
    let writeMaximum: Double
    /// D146: the highest read and the highest write the bars show, iStat's
    /// peak row (without the scales' 1 KB/s floor); nil without a bar.
    let readPeak: Double?
    let writePeak: Double?
    let range: (start: Date, end: Date, dataStart: Date)
    /// D130, D131: `bucketing` as `GeekPreparedLineFrame`'s. A rate is a
    /// sample at its own time, as iStat's, not spread over the interval it
    /// was measured across.
    init(points allPoints: [NativeDiskIOPoint], plot: CGRect, duration: TimeInterval, reference: Date, scale: CGFloat,
         bucketing: GeekChartBucketing = .projection) {
        let points = MenuBarHistoryRetention.selected(allPoints, duration: duration, date: \.date, referenceDate: reference)
        let dates = points.map(\.date)
        let window = GeekChartWindow.barRange(for: dates, duration: duration, referenceDate: reference)
        var buckets: [GeekChartBucketSnapshot]
        switch bucketing {
        case .samples:
            buckets = GeekIStatSampleBars.buckets(dates: dates, plotRect: plot, displayScale: scale,
                referenceDate: reference, isSample: { points[$0].bucketStatistics == nil })
            range = GeekIStatHistoryBuckets.range(of: buckets.filter { !$0.indices.isEmpty }, fallback: reference)
        case .history:
            buckets = GeekIStatHistoryBuckets.buckets(dates: dates,
                interval: GeekIStatHistoryBuckets.interval(for: duration), plotRect: plot,
                referenceDate: reference, displayScale: scale,
                gaps: MenuBarSamplingGaps.shared.intervals(at: reference),
                weight: { Double(max(1, points[$0].bucketStatistics?.metrics["diskRead"]?.sampleCount ?? 1)) })
            range = GeekIStatHistoryBuckets.range(of: buckets, fallback: reference)
        case .projection:
            range = window
            buckets = GeekChartWindow.displayBuckets(for: dates, in: plot, range: window,
                referenceDate: reference, displayScale: scale,
                intervalStart: { points[$0].intervalStart }, holdLatestWhileFresh: true)
        }
        let compressed = bucketing == .projection && points.contains { $0.bucketStatistics != nil }
        let estimates = bucketing == .projection && !compressed
        if compressed {
            let gaps = MenuBarSamplingGaps.shared.intervals(at: reference)
            buckets = GeekCompressedHistoryProjection.buckets(buckets, dates: dates,
                records: points.indices.map { points[$0].statistics(previous: $0 > 0 ? points[$0 - 1] : nil, gaps: gaps).metrics["diskRead"] })
        }
        self.buckets = buckets
        let reads = buckets.map { $0.displayValue { points[$0].bucketStatistics?.metrics["diskRead"]?.mean ?? Double(points[$0].readBytesPerSecond) } }
        let writes = buckets.map { $0.displayValue { points[$0].bucketStatistics?.metrics["diskWrite"]?.mean ?? Double(points[$0].writeBytesPerSecond) } }
        self.reads = reads
        self.writes = writes
        readMaximum = GeekBarChartScale.throughputUpperBound(for: reads.compactMap { $0 })
        writeMaximum = GeekBarChartScale.throughputUpperBound(for: writes.compactMap { $0 })
        readPeak = reads.compactMap { $0 }.filter(\.isFinite).max()
        writePeak = writes.compactMap { $0 }.filter(\.isFinite).max()
        func marks(_ values: [Double?]) -> [GeekMirroredBarMark] {
            let filled = !estimates
                ? values.enumerated().map { TimeBucketValue(value: $0.element, isEstimated: false, sourceIndex: $0.offset) }
                : TimeBucketAggregator.nearestFilled(values)
            return zip(buckets, filled).compactMap { bucket, value in
                value.value.map { GeekMirroredBarMark(x: bucket.x, value: $0,
                    isEstimated: bucket.isEstimated || value.isEstimated) }
            }
        }
        readMarks = marks(reads)
        writeMarks = marks(writes)
    }
}
