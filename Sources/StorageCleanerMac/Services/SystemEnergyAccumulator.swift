import AppKit
import Darwin
import Foundation

enum SystemEnergyPowerSource: String, Codable, Equatable, Sendable {
    case ac
    case battery
    case unknown
}

enum SystemEnergySampleConfidence: String, Codable, Equatable, Sendable {
    case measured
    case estimated
}

struct SystemEnergyPowerSample: Codable, Equatable, Sendable {
    let monotonicSeconds: TimeInterval
    let wallClock: Date
    let watts: Double
    let powerSource: SystemEnergyPowerSource
    let confidence: SystemEnergySampleConfidence
    let source: String

    var isValid: Bool {
        monotonicSeconds.isFinite
            && monotonicSeconds >= 0
            && wallClock.timeIntervalSinceReferenceDate.isFinite
            && watts.isFinite
            && watts >= 0
    }
}

struct SystemEnergyBootIdentity: Equatable, Sendable {
    let identifier: String
    let startedAt: Date
    let uptimeSeconds: TimeInterval

    static func current(now: Date = Date()) -> SystemEnergyBootIdentity {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0,
           bootTime.tv_sec > 0 {
            let startedAt = Date(
                timeIntervalSince1970: TimeInterval(bootTime.tv_sec)
                    + TimeInterval(bootTime.tv_usec) / 1_000_000
            )
            return SystemEnergyBootIdentity(
                identifier: "\(bootTime.tv_sec).\(bootTime.tv_usec)",
                startedAt: startedAt,
                uptimeSeconds: max(0, now.timeIntervalSince(startedAt))
            )
        }

        let uptime = max(0, ProcessInfo.processInfo.systemUptime)
        let startedAt = now.addingTimeInterval(-uptime)
        return SystemEnergyBootIdentity(
            identifier: String(Int(startedAt.timeIntervalSince1970.rounded())),
            startedAt: startedAt,
            uptimeSeconds: uptime
        )
    }
}

struct SystemEnergySessionSnapshot: Codable, Equatable, Sendable {
    let bootSessionIdentifier: String
    let bootStartedAt: Date
    let monitoringStartedAt: Date
    var updatedAt: Date
    var acWattHours: Double
    var batteryWattHours: Double
    var measuredSeconds: TimeInterval
    var estimatedSeconds: TimeInterval
    var gapSeconds: TimeInterval
    var lastSample: SystemEnergyPowerSample?

    init(
        boot: SystemEnergyBootIdentity,
        monitoringStartedAt: Date
    ) {
        bootSessionIdentifier = boot.identifier
        bootStartedAt = boot.startedAt
        self.monitoringStartedAt = monitoringStartedAt
        updatedAt = monitoringStartedAt
        acWattHours = 0
        batteryWattHours = 0
        measuredSeconds = 0
        estimatedSeconds = 0
        gapSeconds = 0
        lastSample = nil
    }

    var totalWattHours: Double { acWattHours + batteryWattHours }
    var totalKilowattHours: Double { totalWattHours / 1_000 }
    var coveredSeconds: TimeInterval { measuredSeconds + estimatedSeconds }
    var isEstimated: Bool { estimatedSeconds > 0 || monitoringStartedAt > bootStartedAt.addingTimeInterval(5) }
    var currentPowerWatts: Double? { lastSample?.watts }

    var totalKilowattHoursText: String {
        String(format: "%.3f kWh", locale: Locale(identifier: "en_US_POSIX"), totalKilowattHours)
    }

    var sourceBreakdownText: String {
        let locale = Locale(identifier: "en_US_POSIX")
        return L10n.text(
            String(format: "插电 %.3f · 电池 %.3f kWh", locale: locale, acWattHours / 1_000, batteryWattHours / 1_000),
            String(format: "AC %.3f · Battery %.3f kWh", locale: locale, acWattHours / 1_000, batteryWattHours / 1_000)
        )
    }

    var currentPowerText: String {
        currentPowerWatts.map(EnergyImpactApp.powerText) ?? "—"
    }

    func coveragePercent(uptimeSeconds: TimeInterval) -> Double {
        guard uptimeSeconds > 0 else { return 0 }
        return min(100, max(0, coveredSeconds / uptimeSeconds * 100))
    }

    mutating func append(
        _ sample: SystemEnergyPowerSample,
        maximumInterval: TimeInterval = 90
    ) {
        guard sample.isValid else {
            lastSample = nil
            return
        }
        defer {
            lastSample = sample
            updatedAt = max(updatedAt, sample.wallClock)
        }
        guard let previous = lastSample else { return }

        let interval = sample.monotonicSeconds - previous.monotonicSeconds
        guard interval > 0 else { return }
        guard interval <= maximumInterval else {
            gapSeconds += interval
            return
        }
        guard previous.isValid, previous.powerSource != .unknown else {
            gapSeconds += interval
            return
        }

        let wattHours = ((previous.watts + sample.watts) / 2) * interval / 3_600
        guard wattHours.isFinite, wattHours >= 0 else { return }
        switch previous.powerSource {
        case .ac:
            acWattHours += wattHours
        case .battery:
            batteryWattHours += wattHours
        case .unknown:
            break
        }
        if previous.confidence == .measured && sample.confidence == .measured {
            measuredSeconds += interval
        } else {
            estimatedSeconds += interval
        }
    }

    mutating func markGap(at wallClock: Date) {
        lastSample = nil
        updatedAt = max(updatedAt, wallClock)
    }

    mutating func prepareAfterApplicationRestart(at wallClock: Date) {
        // Persist accumulated totals, but never bridge an unobserved app-quit gap.
        markGap(at: wallClock)
    }
}

enum SystemEnergyAccumulatorLocation {
    static var defaultURL: URL? {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("SystemEnergySession-v1.json")
    }
}

enum SystemEnergySessionStore {
    static func load(from url: URL) -> SystemEnergySessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SystemEnergySessionSnapshot.self, from: data)
    }

    static func save(_ snapshot: SystemEnergySessionSnapshot, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic])
    }
}

actor SystemEnergyPersistenceWriter {
    static let minimumSaveInterval: TimeInterval = 5 * 60

    private var newestUpdatedAt = Date.distantPast
    private var newestTotalWattHours: Double = -1
    private var lastSuccessfulSaveAt = Date.distantPast

    func save(
        _ snapshot: SystemEnergySessionSnapshot,
        to url: URL,
        force: Bool = false
    ) {
        guard snapshot.updatedAt > newestUpdatedAt
            || (snapshot.updatedAt == newestUpdatedAt
                && snapshot.totalWattHours >= newestTotalWattHours) else { return }
        guard force
            || snapshot.updatedAt.timeIntervalSince(lastSuccessfulSaveAt)
                >= Self.minimumSaveInterval else { return }
        do {
            try SystemEnergySessionStore.save(snapshot, to: url)
            newestUpdatedAt = snapshot.updatedAt
            newestTotalWattHours = snapshot.totalWattHours
            lastSuccessfulSaveAt = snapshot.updatedAt
        } catch {
            // A failed write does not advance the throttle, so the next sample
            // immediately retries the same monotonic snapshot.
        }
    }
}

enum SystemEnergyPowerSampleService {
    static func sample() async -> SystemEnergyPowerSample? {
        let now = Date()
        let monotonic = ProcessInfo.processInfo.systemUptime
        let nativePower = NativeBatteryElectricalService.snapshot()
        let nativeSource = BatteryPowerService.currentSystemPowerSource()
        let powerSource: SystemEnergyPowerSource = switch nativeSource {
        case .acPower: .ac
        case .batteryPower: .battery
        case .unknown: .unknown
        }

        if powerSource == .battery,
           let watts = nativePower?.powerWatts.map(abs),
           watts.isFinite,
           watts > 0 {
            return SystemEnergyPowerSample(
                monotonicSeconds: monotonic,
                wallClock: now,
                watts: watts,
                powerSource: .battery,
                confidence: .measured,
                source: "native-battery-voltage-current"
            )
        }

        // macOS exposes no public, portable AC wall-power meter. Reuse the
        // existing attributed-process sampler as an explicitly labelled lower
        // confidence estimate instead of treating adapter rating as live draw.
        let attributed = await Task.detached(priority: .utility) {
            await EnergyImpactService.snapshot(sampleInterval: .milliseconds(600))
        }.value
        let watts = attributed.totalCurrentPowerWatts
        guard watts.isFinite, watts > 0 else { return nil }
        return SystemEnergyPowerSample(
            monotonicSeconds: ProcessInfo.processInfo.systemUptime,
            wallClock: Date(),
            watts: watts,
            powerSource: powerSource,
            confidence: .estimated,
            source: "attributed-process-estimate"
        )
    }
}

@MainActor
final class SystemEnergyAccumulator {
    typealias SampleProvider = @Sendable () async -> SystemEnergyPowerSample?
    static let samplingInterval: Duration = .seconds(30)

    private(set) var snapshot: SystemEnergySessionSnapshot
    var onSnapshot: ((SystemEnergySessionSnapshot) -> Void)?

    private let fileURL: URL?
    private let sampleProvider: SampleProvider
    private let persistenceWriter = SystemEnergyPersistenceWriter()
    private var monitorTask: Task<Void, Never>?
    private var powerSourceObserver: BatteryPowerSourceObserver?
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        fileURL: URL? = SystemEnergyAccumulatorLocation.defaultURL,
        boot: SystemEnergyBootIdentity = .current(),
        now: Date = Date(),
        sampleProvider: @escaping SampleProvider = SystemEnergyPowerSampleService.sample
    ) {
        self.fileURL = fileURL
        self.sampleProvider = sampleProvider
        if let fileURL,
           var restored = SystemEnergySessionStore.load(from: fileURL),
           restored.bootSessionIdentifier == boot.identifier {
            restored.prepareAfterApplicationRestart(at: now)
            snapshot = restored
        } else {
            snapshot = SystemEnergySessionSnapshot(boot: boot, monitoringStartedAt: now)
        }
    }

    func start() {
        guard monitorTask == nil else { return }
        observeLifecycle()
        powerSourceObserver = BatteryPowerSourceObserver { [weak self] in
            Task { @MainActor in await self?.sampleNow() }
        }
        powerSourceObserver?.start()
        monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await sampleNow()
                do {
                    try await Task.sleep(for: Self.samplingInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stopAndFlush() async {
        monitorTask?.cancel()
        monitorTask = nil
        powerSourceObserver = nil
        stopObservingLifecycle()
        await persist()
    }

    func sampleNow() async {
        guard let sample = await sampleProvider() else {
            snapshot.markGap(at: Date())
            publish()
            return
        }
        record(sample)
    }

    func record(_ sample: SystemEnergyPowerSample) {
        snapshot.append(sample)
        publish()
    }

    func markSleep(at date: Date = Date()) {
        snapshot.markGap(at: date)
        publish(forcePersistence: true)
    }

    func markWake(at date: Date = Date()) {
        snapshot.markGap(at: date)
        publish()
        Task { @MainActor [weak self] in await self?.sampleNow() }
    }

    private func publish(forcePersistence: Bool = false) {
        onSnapshot?(snapshot)
        Task { [snapshot, fileURL, persistenceWriter, forcePersistence] in
            guard let fileURL else { return }
            await persistenceWriter.save(
                snapshot,
                to: fileURL,
                force: forcePersistence
            )
        }
    }

    private func persist() async {
        guard let fileURL else { return }
        let snapshot = snapshot
        await persistenceWriter.save(snapshot, to: fileURL, force: true)
    }

    private func observeLifecycle() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    MenuBarSamplingGaps.shared.begin(.sleep)
                    self?.markSleep()
                }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    MenuBarSamplingGaps.shared.end(.sleep)
                    self?.markWake()
                }
            },
        ]
    }

    private func stopObservingLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }
}
