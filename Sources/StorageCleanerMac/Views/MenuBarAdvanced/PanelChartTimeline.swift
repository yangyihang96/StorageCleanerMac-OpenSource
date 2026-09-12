import Foundation
import SwiftUI

struct ChartActivityPolicy: Equatable {
    let isPanelVisible: Bool
    let isDisplayAwake: Bool
    let isLowPowerModeEnabled: Bool
    let thermalState: ProcessInfo.ThermalState
    let reduceMotion: Bool

    func refreshInterval(for duration: TimeInterval) -> TimeInterval? {
        guard isPanelVisible, isDisplayAwake, !reduceMotion else { return nil }
        guard thermalState != .critical else { return nil }

        let normal = GeekLiveChartTimeline<EmptyView>.refreshInterval(
            for: duration,
            reduceMotion: false
        )
        if thermalState == .serious { return max(2, normal) }
        if isLowPowerModeEnabled { return max(2, normal) }
        return normal
    }
}

struct PanelChartTimeAnchor: Sendable {
    static let significantDrift: TimeInterval = 2

    let wallDate: Date
    let instant: ContinuousClock.Instant

    init(
        wallDate: Date = Date(),
        instant: ContinuousClock.Instant = ContinuousClock().now
    ) {
        self.wallDate = wallDate
        self.instant = instant
    }

    func elapsed(to now: ContinuousClock.Instant) -> TimeInterval {
        let duration = instant.duration(to: now)
        let components = duration.components
        return max(
            0,
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }

    func referenceDate(now: ContinuousClock.Instant) -> Date {
        wallDate.addingTimeInterval(elapsed(to: now))
    }

    func wallClockDrift(
        observedWallDate: Date,
        now: ContinuousClock.Instant
    ) -> TimeInterval {
        observedWallDate.timeIntervalSince(referenceDate(now: now))
    }
}

enum PanelChartClockEpochReason: Equatable, Sendable {
    case significantWallClockDrift(TimeInterval)
}

/// Holds a chart's already-quantized upper bound steady between live redraws.
/// The caller supplies the target tier; expansion is immediate so peaks are
/// never clipped, while a lower tier is reached over a short, deterministic
/// interval to avoid an axis that visibly pumps with each sample.
struct PanelChartAxisScaleState {
    static let defaultDecayDuration: TimeInterval = 10

    private struct Decay {
        let start: Double
        let target: Double
        let beganAt: Date
    }

    private(set) var displayMaximum: Double?
    private var decay: Decay?
    private let decayDuration: TimeInterval

    init(decayDuration: TimeInterval = Self.defaultDecayDuration) {
        self.decayDuration = max(0, decayDuration)
    }

    func displayedMaximum(fallback: Double) -> Double {
        displayMaximum ?? Self.validMaximum(fallback)
    }

    @discardableResult
    mutating func update(targetMaximum: Double, at date: Date) -> Double {
        let target = Self.validMaximum(targetMaximum)
        guard let previousMaximum = displayMaximum else {
            displayMaximum = target
            decay = nil
            return target
        }

        let current = projectedMaximum(at: date, fallback: previousMaximum)
        guard target < current else {
            displayMaximum = target
            decay = nil
            return target
        }

        if decay?.target != target {
            decay = Decay(start: current, target: target, beganAt: date)
        }
        displayMaximum = current
        return current
    }

    private func projectedMaximum(at date: Date, fallback: Double) -> Double {
        guard let decay else { return fallback }
        guard decayDuration > 0 else { return decay.target }

        let elapsed = max(0, date.timeIntervalSince(decay.beganAt))
        let progress = min(1, elapsed / decayDuration)
        return decay.start + (decay.target - decay.start) * progress
    }

    private static func validMaximum(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }
}

@MainActor
final class PanelChartAxisScale: ObservableObject {
    @Published private(set) var displayMaximum: Double?

    private var state = PanelChartAxisScaleState()

    func displayedMaximum(fallback: Double) -> Double {
        displayMaximum ?? state.displayedMaximum(fallback: fallback)
    }

    func update(targetMaximum: Double, at date: Date) {
        let next = state.update(targetMaximum: targetMaximum, at: date)
        guard displayMaximum != next else { return }
        displayMaximum = next
    }
}

@MainActor
final class PanelChartClock: ObservableObject {
    @Published private(set) var referenceDate: Date
    @Published private(set) var epoch = 0
    @Published private(set) var lastEpochReason: PanelChartClockEpochReason?

    private var anchor: PanelChartTimeAnchor
    private let clock: ContinuousClock
    private var latestSampleDate: Date?
    var scheduleStart: Date { anchor.wallDate }

    init(anchor providedAnchor: PanelChartTimeAnchor? = nil) {
        let clock = ContinuousClock()
#if DEBUG || STORAGE_CLEANER_BETA
        if providedAnchor == nil, MiniWindowDemoData.isEnabled {
            self.clock = clock
            self.anchor = PanelChartTimeAnchor(
                wallDate: MiniWindowDemoData.referenceDate,
                instant: clock.now
            )
            referenceDate = MiniWindowDemoData.referenceDate
            return
        }
#endif
        let anchor = providedAnchor ?? PanelChartTimeAnchor(
            wallDate: Date(),
            instant: clock.now
        )
        self.clock = clock
        self.anchor = anchor
        referenceDate = anchor.referenceDate(now: clock.now)
    }

    func advance(
        wallDate: Date = Date(),
        instant: ContinuousClock.Instant? = nil
    ) {
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else { return }
#endif
        let currentInstant = instant ?? clock.now
        let drift = anchor.wallClockDrift(
            observedWallDate: wallDate,
            now: currentInstant
        )
        if abs(drift) >= PanelChartTimeAnchor.significantDrift {
            anchor = PanelChartTimeAnchor(
                wallDate: wallDate,
                instant: currentInstant
            )
            epoch += 1
            lastEpochReason = .significantWallClockDrift(drift)
            referenceDate = wallDate
            PerformanceTelemetry.signposter.emitEvent("ChartUpdate")
            return
        }

        let next = anchor.referenceDate(now: currentInstant)
        guard next > referenceDate else { return }
        referenceDate = next
        PerformanceTelemetry.signposter.emitEvent("ChartUpdate")
    }

    func receiveSampleDate(
        _ sampleDate: Date?,
        wallDate: Date = Date(),
        instant: ContinuousClock.Instant? = nil
    ) {
        guard let sampleDate, sampleDate.timeIntervalSinceReferenceDate.isFinite,
              sampleDate != latestSampleDate else { return }
        latestSampleDate = sampleDate
        advance(wallDate: wallDate, instant: instant)
    }
}

private struct PanelChartClockKey: EnvironmentKey {
    static let defaultValue: PanelChartClock? = nil
}

extension EnvironmentValues {
    var panelChartClock: PanelChartClock? {
        get { self[PanelChartClockKey.self] }
        set { self[PanelChartClockKey.self] = newValue }
    }
}

struct PanelChartTimeline<Content: View>: View {
    let duration: TimeInterval
    let policy: ChartActivityPolicy
    let sampleSource: MenuBarMonitorState?
    private let content: Content
    @StateObject private var sharedClock = PanelChartClock()

    init(
        duration: TimeInterval,
        policy: ChartActivityPolicy,
        sampleSource: MenuBarMonitorState? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.duration = duration
        self.policy = policy
        self.sampleSource = sampleSource
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.panelChartClock, sharedClock)
            .background {
                if let sampleSource {
                    PanelChartSampleClockDriver(
                        source: sampleSource,
                        interval: policy.refreshInterval(for: duration),
                        isActive: policy.isPanelVisible && policy.isDisplayAwake,
                        sharedClock: sharedClock
                    )
                } else {
                    PanelChartClockDriver(
                        interval: policy.refreshInterval(for: duration),
                        sharedClock: sharedClock,
                        latestSampleDate: nil
                    )
                }
            }
    }
}

enum PanelChartDateFormatting {
    static let oneDay: TimeInterval = 86_400

    private struct FormatterKey: Hashable {
        let localeIdentifier: String
        let timeZoneIdentifier: String
        let includesDate: Bool
    }

    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [FormatterKey: DateFormatter] = [:]

        func string(
            for date: Date,
            locale: Locale,
            timeZone: TimeZone,
            includesDate: Bool
        ) -> String {
            lock.withLock {
                let key = FormatterKey(
                    localeIdentifier: locale.identifier,
                    timeZoneIdentifier: timeZone.identifier,
                    includesDate: includesDate
                )
                if let formatter = formatters[key] {
                    return formatter.string(from: date)
                }
                let formatter = makeFormatter(
                    locale: locale,
                    timeZone: timeZone,
                    includesDate: includesDate
                )
                formatters[key] = formatter
                return formatter.string(from: date)
            }
        }

        private func makeFormatter(
            locale: Locale,
            timeZone: TimeZone,
            includesDate: Bool
        ) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            if includesDate {
                if locale.identifier.lowercased().hasPrefix("zh") {
                    formatter.dateFormat = "M月d日 a h:mm"
                } else {
                    formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
                }
            } else {
                formatter.dateStyle = .none
                formatter.timeStyle = .medium
            }
            return formatter
        }
    }

    private static let formatterCache = FormatterCache()

    static func includesDate(for visibleDuration: TimeInterval) -> Bool {
        visibleDuration > oneDay
    }

    static func string(
        for date: Date,
        visibleDuration: TimeInterval,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        formatterCache.string(
            for: date,
            locale: locale,
            timeZone: timeZone,
            includesDate: includesDate(for: visibleDuration)
        )
    }
}

/// Observes existing samples locally; it neither polls nor redraws the whole
/// panel. Real readings remain visible even when empty animation ticks stop.
private struct PanelChartSampleClockDriver: View {
    @ObservedObject var source: MenuBarMonitorState
    let interval: TimeInterval?
    let isActive: Bool
    let sharedClock: PanelChartClock

    var body: some View {
        PanelChartClockDriver(
            interval: interval,
            sharedClock: sharedClock,
            latestSampleDate: isActive ? source.snapshot?.generatedAt : nil
        )
    }
}

private struct PanelChartClockDriver: View {
    let interval: TimeInterval?
    @ObservedObject var sharedClock: PanelChartClock
    let latestSampleDate: Date?

    @ViewBuilder
    var body: some View {
        Group {
            if let interval {
                TimelineView(.periodic(from: sharedClock.scheduleStart, by: interval)) { timeline in
                    Color.clear
                        .onAppear { advanceAfterCurrentRender() }
                        .onChange(of: timeline.date) { advanceAfterCurrentRender() }
                }
            } else {
                Color.clear
                    .onAppear { advanceAfterCurrentRender() }
            }
        }
        .onChange(of: latestSampleDate) {
            Task { @MainActor in
                sharedClock.receiveSampleDate(latestSampleDate)
            }
        }
    }

    private func advanceAfterCurrentRender() {
        Task { @MainActor in
            sharedClock.advance()
        }
    }
}
