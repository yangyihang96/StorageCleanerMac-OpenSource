import CoreGraphics
import CoreVideo
import Foundation

/// Read-only display cadence measurement. Its results are intentionally not a
/// `MacBenchmark` component and must never be folded into a Core score.
public struct DisplayCadenceKernel: Sendable {
    public static let workloadVersion = "display-cadence-v8"
    public static let statisticsVersion = "display-cadence-statistics-v1"

    public struct Configuration: Equatable, Sendable {
        public static let maximumSampleLimit = 10_000
        public static let maximumTimeoutSeconds = 30.0

        public let sampleLimit: Int
        public let minimumIntervalCount: Int
        public let timeoutSeconds: Double

        public init(
            sampleLimit: Int = 240,
            minimumIntervalCount: Int = 60,
            timeoutSeconds: Double = 5
        ) {
            self.sampleLimit = sampleLimit
            self.minimumIntervalCount = minimumIntervalCount
            self.timeoutSeconds = timeoutSeconds
        }

        public static let standard = Self()
    }

    private let configuration: Configuration
    private let provider: any DisplayCadenceSampleProviding

    public init(
        configuration: Configuration = .standard,
        provider: any DisplayCadenceSampleProviding = SystemDisplayCadenceSampleProvider()
    ) {
        self.configuration = configuration
        self.provider = provider
    }

    public func measure() async -> DisplayCadenceReport {
        guard Self.isValid(configuration) else {
            return Self.unavailableReport(
                metadata: nil,
                timestampCount: 0,
                reason: .invalidConfiguration
            )
        }

        let batch = await provider.capture(configuration: configuration)
        guard let reason = batch.unavailableReason else {
            return Self.summarize(batch, configuration: configuration)
        }
        return Self.unavailableReport(
            metadata: batch.declaredMetadata,
            timestampCount: batch.hostTimeTimestamps.count,
            reason: reason
        )
    }

    /// Public so deterministic fixtures can exercise the exact production
    /// aggregation without a physical display or an active display link.
    public static func summarize(
        _ batch: DisplayCadenceSampleBatch,
        configuration: Configuration = .standard
    ) -> DisplayCadenceReport {
        guard isValid(configuration) else {
            return unavailableReport(
                metadata: batch.declaredMetadata,
                timestampCount: batch.hostTimeTimestamps.count,
                reason: .invalidConfiguration
            )
        }
        if let reason = batch.unavailableReason {
            return unavailableReport(
                metadata: batch.declaredMetadata,
                timestampCount: batch.hostTimeTimestamps.count,
                reason: reason
            )
        }
        guard let frequency = batch.hostClockFrequency,
              frequency.isFinite,
              frequency > 0
        else {
            return unavailableReport(
                metadata: batch.declaredMetadata,
                timestampCount: batch.hostTimeTimestamps.count,
                reason: .invalidHostClock
            )
        }

        let timestamps = batch.hostTimeTimestamps
        guard timestamps.count >= configuration.minimumIntervalCount + 1 else {
            return unavailableReport(
                metadata: batch.declaredMetadata,
                timestampCount: timestamps.count,
                reason: .insufficientTimestamps
            )
        }

        var intervals = [Double]()
        intervals.reserveCapacity(timestamps.count - 1)
        for (previous, next) in zip(timestamps, timestamps.dropFirst()) {
            guard next > previous else {
                return unavailableReport(
                    metadata: batch.declaredMetadata,
                    timestampCount: timestamps.count,
                    reason: .nonMonotonicTimestamp
                )
            }
            let seconds = Double(next - previous) / frequency
            guard seconds.isFinite, seconds > 0 else {
                return unavailableReport(
                    metadata: batch.declaredMetadata,
                    timestampCount: timestamps.count,
                    reason: .invalidHostClock
                )
            }
            intervals.append(seconds)
        }

        guard let first = timestamps.first,
              let last = timestamps.last,
              last > first
        else {
            return unavailableReport(
                metadata: batch.declaredMetadata,
                timestampCount: timestamps.count,
                reason: .nonMonotonicTimestamp
            )
        }

        let elapsedSeconds = Double(last - first) / frequency
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else {
            return unavailableReport(
                metadata: batch.declaredMetadata,
                timestampCount: timestamps.count,
                reason: .invalidHostClock
            )
        }

        let sortedMilliseconds = intervals.map { $0 * 1_000 }.sorted()
        guard let p50 = percentile(0.50, sortedValues: sortedMilliseconds),
              let p95 = percentile(0.95, sortedValues: sortedMilliseconds),
              let p99 = percentile(0.99, sortedValues: sortedMilliseconds)
        else {
            return unavailableReport(
                metadata: batch.declaredMetadata,
                timestampCount: timestamps.count,
                reason: .insufficientTimestamps
            )
        }

        let sumOfSquaredDeviation = sortedMilliseconds.reduce(0) { partial, value in
            let deviation = value - p50
            return partial + (deviation * deviation)
        }
        let jitterMilliseconds = sqrt(sumOfSquaredDeviation / Double(sortedMilliseconds.count))
        let effectiveFramesPerSecond = Double(intervals.count) / elapsedSeconds
        let relativeJitter = jitterMilliseconds / p50
        guard jitterMilliseconds.isFinite,
              jitterMilliseconds >= 0,
              effectiveFramesPerSecond.isFinite,
              effectiveFramesPerSecond > 0,
              relativeJitter.isFinite,
              relativeJitter >= 0
        else {
            return unavailableReport(
                metadata: batch.declaredMetadata,
                timestampCount: timestamps.count,
                reason: .invalidHostClock
            )
        }

        let stability: DisplayCadenceStability = relativeJitter <= 0.05 ? .stable : .variable
        let metrics = DisplayCadenceMetrics(
            timestampCount: timestamps.count,
            intervalCount: intervals.count,
            measuredDurationSeconds: elapsedSeconds,
            effectiveFramesPerSecond: effectiveFramesPerSecond,
            p50IntervalMilliseconds: p50,
            p95IntervalMilliseconds: p95,
            p99IntervalMilliseconds: p99,
            jitterMilliseconds: jitterMilliseconds,
            relativeJitter: relativeJitter,
            stability: stability
        )
        return DisplayCadenceReport(
            workloadVersion: workloadVersion,
            statisticsVersion: statisticsVersion,
            declaredMetadata: batch.declaredMetadata,
            outcome: .measured(metrics)
        )
    }
}

private extension DisplayCadenceKernel {
    static func isValid(_ configuration: Configuration) -> Bool {
        configuration.sampleLimit > 1
            && configuration.sampleLimit <= Configuration.maximumSampleLimit
            && configuration.minimumIntervalCount > 0
            && configuration.minimumIntervalCount < configuration.sampleLimit
            && configuration.timeoutSeconds.isFinite
            && configuration.timeoutSeconds > 0
            && configuration.timeoutSeconds <= Configuration.maximumTimeoutSeconds
    }

    static func unavailableReport(
        metadata: DisplayCadenceDeclaredMetadata?,
        timestampCount: Int,
        reason: DisplayCadenceUnavailableReason
    ) -> DisplayCadenceReport {
        DisplayCadenceReport(
            workloadVersion: workloadVersion,
            statisticsVersion: statisticsVersion,
            declaredMetadata: metadata,
            outcome: .unavailable(
                DisplayCadenceUnavailable(
                    reason: reason,
                    capturedTimestampCount: timestampCount
                )
            )
        )
    }

    /// Linear interpolation on ranks `(count - 1) * probability`.
    static func percentile(_ probability: Double, sortedValues: [Double]) -> Double? {
        guard probability.isFinite,
              (0...1).contains(probability),
              let first = sortedValues.first,
              sortedValues.allSatisfy({ $0.isFinite && $0 > 0 })
        else {
            return nil
        }
        guard sortedValues.count > 1 else { return first }

        let rank = Double(sortedValues.count - 1) * probability
        let lowerIndex = Int(rank.rounded(.down))
        let upperIndex = Int(rank.rounded(.up))
        guard lowerIndex >= 0, upperIndex < sortedValues.count else { return nil }
        if lowerIndex == upperIndex { return sortedValues[lowerIndex] }
        return sortedValues[lowerIndex]
            + ((sortedValues[upperIndex] - sortedValues[lowerIndex]) * (rank - Double(lowerIndex)))
    }
}

public protocol DisplayCadenceSampleProviding: Sendable {
    func capture(configuration: DisplayCadenceKernel.Configuration) async -> DisplayCadenceSampleBatch
}

public struct DisplayCadenceSampleBatch: Equatable, Sendable {
    public let declaredMetadata: DisplayCadenceDeclaredMetadata?
    public let hostTimeTimestamps: [UInt64]
    public let hostClockFrequency: Double?
    public let unavailableReason: DisplayCadenceUnavailableReason?

    public init(
        declaredMetadata: DisplayCadenceDeclaredMetadata?,
        hostTimeTimestamps: [UInt64],
        hostClockFrequency: Double?,
        unavailableReason: DisplayCadenceUnavailableReason? = nil
    ) {
        self.declaredMetadata = declaredMetadata
        self.hostTimeTimestamps = hostTimeTimestamps
        self.hostClockFrequency = hostClockFrequency
        self.unavailableReason = unavailableReason
    }
}

public struct DisplayCadenceDeclaredMetadata: Equatable, Sendable {
    /// This transient CoreGraphics ID is useful for correlating a single result
    /// with its active mode. It is not a hardware serial number.
    public let displayID: UInt32
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let scaleFactor: Double?
    public let declaredRefreshRateHz: Double?
    public let isMirrored: Bool
    public let isBuiltin: Bool

    public init(
        displayID: UInt32,
        pixelWidth: Int,
        pixelHeight: Int,
        logicalWidth: Int,
        logicalHeight: Int,
        scaleFactor: Double?,
        declaredRefreshRateHz: Double?,
        isMirrored: Bool,
        isBuiltin: Bool
    ) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.scaleFactor = scaleFactor
        self.declaredRefreshRateHz = declaredRefreshRateHz
        self.isMirrored = isMirrored
        self.isBuiltin = isBuiltin
    }
}

public enum DisplayCadenceUnavailableReason: String, Equatable, Sendable {
    case invalidConfiguration
    case displayUnavailable
    case displayLinkUnavailable
    case insufficientTimestamps
    case invalidHostClock
    case nonMonotonicTimestamp
    case displayChangedDuringCapture
    case cancelled
}

public struct DisplayCadenceReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case measured(DisplayCadenceMetrics)
        case unavailable(DisplayCadenceUnavailable)
    }

    public let workloadVersion: String
    public let statisticsVersion: String
    public let declaredMetadata: DisplayCadenceDeclaredMetadata?
    public let outcome: Outcome

    public init(
        workloadVersion: String,
        statisticsVersion: String,
        declaredMetadata: DisplayCadenceDeclaredMetadata?,
        outcome: Outcome
    ) {
        self.workloadVersion = workloadVersion
        self.statisticsVersion = statisticsVersion
        self.declaredMetadata = declaredMetadata
        self.outcome = outcome
    }
}

public struct DisplayCadenceMetrics: Equatable, Sendable {
    public let timestampCount: Int
    public let intervalCount: Int
    public let measuredDurationSeconds: Double
    public let effectiveFramesPerSecond: Double
    public let p50IntervalMilliseconds: Double
    public let p95IntervalMilliseconds: Double
    public let p99IntervalMilliseconds: Double
    /// Root-mean-square deviation from the P50 interval; lower is steadier.
    public let jitterMilliseconds: Double
    public let relativeJitter: Double
    public let stability: DisplayCadenceStability

    public init(
        timestampCount: Int,
        intervalCount: Int,
        measuredDurationSeconds: Double,
        effectiveFramesPerSecond: Double,
        p50IntervalMilliseconds: Double,
        p95IntervalMilliseconds: Double,
        p99IntervalMilliseconds: Double,
        jitterMilliseconds: Double,
        relativeJitter: Double,
        stability: DisplayCadenceStability
    ) {
        self.timestampCount = timestampCount
        self.intervalCount = intervalCount
        self.measuredDurationSeconds = measuredDurationSeconds
        self.effectiveFramesPerSecond = effectiveFramesPerSecond
        self.p50IntervalMilliseconds = p50IntervalMilliseconds
        self.p95IntervalMilliseconds = p95IntervalMilliseconds
        self.p99IntervalMilliseconds = p99IntervalMilliseconds
        self.jitterMilliseconds = jitterMilliseconds
        self.relativeJitter = relativeJitter
        self.stability = stability
    }
}

public enum DisplayCadenceStability: String, Equatable, Sendable {
    case stable
    case variable
}

public struct DisplayCadenceUnavailable: Equatable, Sendable {
    public let reason: DisplayCadenceUnavailableReason
    public let capturedTimestampCount: Int

    public init(reason: DisplayCadenceUnavailableReason, capturedTimestampCount: Int) {
        self.reason = reason
        self.capturedTimestampCount = capturedTimestampCount
    }
}

/// The production provider owns the display link only for the bounded capture.
/// It returns an explicit unavailable result instead of guessing from a display
/// mode whenever CoreVideo cannot provide real callback timing.
public struct SystemDisplayCadenceSampleProvider: DisplayCadenceSampleProviding {
    private let requestedDisplayID: UInt32?

    public init(displayID: UInt32? = nil) {
        requestedDisplayID = displayID
    }

    public func capture(configuration: DisplayCadenceKernel.Configuration) async -> DisplayCadenceSampleBatch {
        let requestedDisplayID = requestedDisplayID
        let task = Task.detached(priority: .userInitiated) {
            Self.captureSynchronously(
                displayID: requestedDisplayID,
                configuration: configuration
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private extension SystemDisplayCadenceSampleProvider {
    static func captureSynchronously(
        displayID requestedDisplayID: UInt32?,
        configuration: DisplayCadenceKernel.Configuration
    ) -> DisplayCadenceSampleBatch {
        guard configuration.sampleLimit > 1,
              configuration.sampleLimit <= DisplayCadenceKernel.Configuration.maximumSampleLimit,
              configuration.minimumIntervalCount > 0,
              configuration.minimumIntervalCount < configuration.sampleLimit,
              configuration.timeoutSeconds.isFinite,
              configuration.timeoutSeconds > 0,
              configuration.timeoutSeconds <= DisplayCadenceKernel.Configuration.maximumTimeoutSeconds
        else {
            return DisplayCadenceSampleBatch(
                declaredMetadata: nil,
                hostTimeTimestamps: [],
                hostClockFrequency: nil,
                unavailableReason: .invalidConfiguration
            )
        }

        let displayID = CGDirectDisplayID(requestedDisplayID ?? CGMainDisplayID())
        guard let metadata = declaredMetadata(for: displayID) else {
            return DisplayCadenceSampleBatch(
                declaredMetadata: nil,
                hostTimeTimestamps: [],
                hostClockFrequency: nil,
                unavailableReason: .displayUnavailable
            )
        }
        guard !Task.isCancelled else {
            return DisplayCadenceSampleBatch(
                declaredMetadata: metadata,
                hostTimeTimestamps: [],
                hostClockFrequency: nil,
                unavailableReason: .cancelled
            )
        }

        let frequency = CVGetHostClockFrequency()
        guard frequency.isFinite, frequency > 0 else {
            return DisplayCadenceSampleBatch(
                declaredMetadata: metadata,
                hostTimeTimestamps: [],
                hostClockFrequency: nil,
                unavailableReason: .invalidHostClock
            )
        }

        var displayLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &displayLink) == kCVReturnSuccess,
              let displayLink
        else {
            return DisplayCadenceSampleBatch(
                declaredMetadata: metadata,
                hostTimeTimestamps: [],
                hostClockFrequency: frequency,
                unavailableReason: .displayLinkUnavailable
            )
        }

        let captureBox = DisplayCadenceCaptureBox(maximumCount: configuration.sampleLimit)
        let retainedBox = Unmanaged.passRetained(captureBox)
        let context = retainedBox.toOpaque()
        var didStart = false
        defer {
            if didStart { CVDisplayLinkStop(displayLink) }
            CVDisplayLinkSetOutputCallback(displayLink, nil, nil)
            retainedBox.release()
        }

        guard CVDisplayLinkSetOutputCallback(displayLink, displayCadenceOutputCallback, context) == kCVReturnSuccess,
              CVDisplayLinkStart(displayLink) == kCVReturnSuccess
        else {
            return DisplayCadenceSampleBatch(
                declaredMetadata: metadata,
                hostTimeTimestamps: [],
                hostClockFrequency: frequency,
                unavailableReason: .displayLinkUnavailable
            )
        }
        didStart = true

        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(configuration.timeoutSeconds * 1_000_000_000)
        while captureBox.count < configuration.sampleLimit,
              DispatchTime.now().uptimeNanoseconds < deadline {
            if Task.isCancelled {
                return DisplayCadenceSampleBatch(
                    declaredMetadata: metadata,
                    hostTimeTimestamps: captureBox.timestamps,
                    hostClockFrequency: frequency,
                    unavailableReason: .cancelled
                )
            }
            Thread.sleep(forTimeInterval: 0.004)
        }

        guard !Task.isCancelled else {
            return DisplayCadenceSampleBatch(
                declaredMetadata: metadata,
                hostTimeTimestamps: captureBox.timestamps,
                hostClockFrequency: frequency,
                unavailableReason: .cancelled
            )
        }

        guard declaredMetadata(for: displayID) == metadata else {
            return DisplayCadenceSampleBatch(
                declaredMetadata: metadata,
                hostTimeTimestamps: captureBox.timestamps,
                hostClockFrequency: frequency,
                unavailableReason: .displayChangedDuringCapture
            )
        }
        let timestamps = captureBox.timestamps
        guard timestamps.count >= configuration.minimumIntervalCount + 1 else {
            return DisplayCadenceSampleBatch(
                declaredMetadata: metadata,
                hostTimeTimestamps: timestamps,
                hostClockFrequency: frequency,
                unavailableReason: .insufficientTimestamps
            )
        }
        return DisplayCadenceSampleBatch(
            declaredMetadata: metadata,
            hostTimeTimestamps: timestamps,
            hostClockFrequency: frequency
        )
    }

    static func declaredMetadata(for displayID: CGDirectDisplayID) -> DisplayCadenceDeclaredMetadata? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let pixelWidth = mode.pixelWidth
        let pixelHeight = mode.pixelHeight
        let logicalWidth = mode.width
        let logicalHeight = mode.height
        guard pixelWidth > 0,
              pixelHeight > 0,
              logicalWidth > 0,
              logicalHeight > 0
        else {
            return nil
        }

        let refreshRate = mode.refreshRate
        return DisplayCadenceDeclaredMetadata(
            displayID: UInt32(displayID),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            scaleFactor: Double(pixelWidth) / Double(logicalWidth),
            declaredRefreshRateHz: refreshRate.isFinite && refreshRate > 0 ? refreshRate : nil,
            isMirrored: CGDisplayIsInMirrorSet(displayID) != 0,
            isBuiltin: CGDisplayIsBuiltin(displayID) != 0
        )
    }
}

private final class DisplayCadenceCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumCount: Int
    private var storedTimestamps = [UInt64]()

    init(maximumCount: Int) {
        self.maximumCount = maximumCount
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedTimestamps.count
    }

    var timestamps: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storedTimestamps
    }

    func append(_ timestamp: UInt64) {
        lock.lock()
        if storedTimestamps.count < maximumCount {
            storedTimestamps.append(timestamp)
        }
        lock.unlock()
    }
}

private func displayCadenceOutputCallback(
    _: CVDisplayLink,
    _: UnsafePointer<CVTimeStamp>,
    _: UnsafePointer<CVTimeStamp>,
    _: CVOptionFlags,
    _: UnsafeMutablePointer<CVOptionFlags>,
    _ context: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let context else { return kCVReturnSuccess }
    // Capture the actual callback arrival on CoreVideo's monotonic clock.
    // `outputTime` is a predicted display time and can be zero on some paths.
    let hostTime = CVGetCurrentHostTime()
    guard hostTime > 0 else { return kCVReturnSuccess }
    Unmanaged<DisplayCadenceCaptureBox>
        .fromOpaque(context)
        .takeUnretainedValue()
        .append(hostTime)
    return kCVReturnSuccess
}
