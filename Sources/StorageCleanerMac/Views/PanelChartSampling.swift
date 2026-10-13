import SwiftUI

enum PanelChartSampling {
    static let minimumRenderableSampleCount = 2
    static let minimumRenderableTimeSpan: TimeInterval = 6

    static var statusText: String {
        L10n.text("正在采样…", "Sampling…")
    }

    static func placeholderText(sampledAt: Date?, isPaused: Bool, now: Date = Date()) -> String {
        if isPaused { return L10n.text("已暂停", "Paused") }
        guard let sampledAt else { return statusText }
        return L10n.text("趋势数据不足 · ", "Insufficient trend data · ") + PanelTimestampFormat.age(sampledAt, now: now)
    }

    static func hasRenderableTrend(_ values: [Double?]) -> Bool {
        var contiguousCount = 0
        for value in values {
            guard let value, value.isFinite else {
                contiguousCount = 0
                continue
            }
            contiguousCount += 1
        }
        return contiguousCount >= minimumRenderableSampleCount
    }

    static func hasRenderableTrend(_ values: [Double]) -> Bool {
        hasRenderableTrend(values.map(Optional.some))
    }

    static func hasRenderableTrend(_ samples: [MenuBarChartSample]) -> Bool {
        // Some sources (notably memory) are sampled less frequently than the
        // one-second status refresh. Nil entries are deliberate no-sample
        // markers, not an instruction to discard the surrounding real series.
        let validDates = samples.compactMap { sample -> Date? in
            guard let value = sample.value, value.isFinite else { return nil }
            return sample.date
        }
        let gapThreshold = samplingGapThreshold(for: validDates)
        var contiguousCount = 0
        var contiguousStartDate: Date?
        var previousValidDate: Date?

        func currentSegmentIsRenderable() -> Bool {
            guard contiguousCount >= minimumRenderableSampleCount,
                  let contiguousStartDate,
                  let previousValidDate else { return false }
            return previousValidDate.timeIntervalSince(contiguousStartDate)
                >= minimumRenderableTimeSpan
        }

        for sample in samples {
            guard let value = sample.value, value.isFinite else {
                continue
            }

            if let previousValidDate,
               sample.date.timeIntervalSince(previousValidDate) > gapThreshold {
                if currentSegmentIsRenderable() { return true }
                contiguousCount = 0
                contiguousStartDate = nil
            }
            if contiguousStartDate == nil {
                contiguousStartDate = sample.date
            }
            contiguousCount += 1
            previousValidDate = sample.date
        }
        return currentSegmentIsRenderable()
    }

    static func samplingGapThreshold(for dates: [Date]) -> TimeInterval {
        let intervals = zip(dates.dropFirst(), dates).compactMap { current, previous -> TimeInterval? in
            let interval = current.timeIntervalSince(previous)
            return interval > 0 ? interval : nil
        }.sorted()
        guard !intervals.isEmpty else { return 5 }
        let lowerMedian = intervals[(intervals.count - 1) / 2]
        return max(5, lowerMedian * 3)
    }

}

private struct PanelStoredSampleDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

private struct PanelAutomaticRefreshPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var panelStoredSampleDate: Date? {
        get { self[PanelStoredSampleDateKey.self] }
        set { self[PanelStoredSampleDateKey.self] = newValue }
    }
    var panelAutomaticRefreshPaused: Bool {
        get { self[PanelAutomaticRefreshPausedKey.self] }
        set { self[PanelAutomaticRefreshPausedKey.self] = newValue }
    }
}

struct PanelChartSamplingPlaceholder: View {
    @Environment(\.panelAutomaticRefreshPaused) private var isPaused
    @Environment(\.panelStoredSampleDate) private var sampledAt

    var body: some View {
        Text(PanelChartSampling.placeholderText(sampledAt: sampledAt, isPaused: isPaused))
            .font(AdvancedPanelTypography.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .accessibilityHidden(true)
            .menuBarTraceProbe { PanelChartPlaceholderProbe() }
    }
}

/// Audit only: `chart.placeholder.<region>`, a chart showed its sampling
/// placeholder instead of data.
private struct PanelChartPlaceholderProbe: View {
    @Environment(\.menuBarTraceRegion) private var region

    var body: some View {
        MenuBarPresentationProbe(key: "chart.placeholder.\(region)")
            .frame(width: 1, height: 1)
    }
}
