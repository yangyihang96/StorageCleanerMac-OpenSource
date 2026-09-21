import Foundation

struct MetricHistorySnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let empty = MetricHistorySnapshot()

    var version: Int
    var telemetry: [MenuBarTelemetryPoint]
    var memoryTelemetry: [MenuBarTelemetryPoint]
    var diskIO: [NativeDiskIOPoint]
    var power: [MenuBarPowerHistoryPoint]

    init(
        version: Int = currentVersion,
        telemetry: [MenuBarTelemetryPoint] = [],
        memoryTelemetry: [MenuBarTelemetryPoint] = [],
        diskIO: [NativeDiskIOPoint] = [],
        power: [MenuBarPowerHistoryPoint] = []
    ) {
        self.version = version
        self.telemetry = telemetry
        self.memoryTelemetry = memoryTelemetry
        self.diskIO = diskIO
        self.power = power
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case telemetry
        case memoryTelemetry
        case diskIO
        case power
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        telemetry = try container.decodeIfPresent(
            BoundedMonitoringArray<MenuBarTelemetryPoint>.self,
            forKey: .telemetry
        )?.values ?? []
        memoryTelemetry = try container.decodeIfPresent(
            BoundedMonitoringArray<MenuBarTelemetryPoint>.self,
            forKey: .memoryTelemetry
        )?.values ?? telemetry.filter {
            $0.memory != nil
                || $0.memoryPressure != nil
                || $0.compressedMemoryBytes != nil
                || $0.swapUsedBytes != nil
        }
        diskIO = try container.decodeIfPresent(
            BoundedMonitoringArray<NativeDiskIOPoint>.self,
            forKey: .diskIO
        )?.values ?? []
        power = try container.decodeIfPresent(
            BoundedMonitoringArray<MenuBarPowerHistoryPoint>.self,
            forKey: .power
        )?.values ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(telemetry, forKey: .telemetry)
        try container.encode(memoryTelemetry, forKey: .memoryTelemetry)
        try container.encode(diskIO, forKey: .diskIO)
        try container.encode(power, forKey: .power)
    }
}

enum MetricHistoryStoreError: Error, Equatable {
    case fileTooLarge
    case preservedUnreadableHistory
    case retryDeferred
}

/// One serial persistence boundary for every menu-bar history series.
///
/// Views only consume immutable arrays. Sampling owners append real readings;
/// the actor validates, compacts and atomically persists them off MainActor.
actor MetricHistoryStore {
    static let saveInterval: TimeInterval = 60
    static let maximumFileSize = 16 * 1_024 * 1_024
    static let futureTolerance: TimeInterval = 5 * 60

    static var defaultURL: URL? {
        MenuBarPowerHistoryStore.defaultURL?
            .deletingLastPathComponent()
            .appendingPathComponent("MetricHistory-v1.json")
    }

    static func live() -> MetricHistoryStore? {
        defaultURL.map {
            MetricHistoryStore(
                url: $0,
                legacyPowerURL: MenuBarPowerHistoryStore.defaultURL
            )
        }
    }

    private let url: URL
    private let legacyPowerURL: URL?
    private let maximumFileSize: Int
    private var cached = MetricHistorySnapshot.empty
    private var isLoaded = false
    private var isDirty = false
    private var revision: UInt64 = 0
    private var persistedRevision: UInt64 = 0
    private var latestMutationAt = Date.distantPast
    private var saveTask: Task<Void, Never>?
    private(set) var saveSchedule = MonitoringSaveSchedule()
    private(set) var loadFailure: String?
    private var lastPersistenceError: (any Error)?
    private let write: @Sendable (Data, URL) throws -> Void

    init(
        url: URL,
        legacyPowerURL: URL? = nil,
        maximumFileSize: Int = MetricHistoryStore.maximumFileSize,
        write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.url = url
        self.legacyPowerURL = legacyPowerURL
        self.maximumFileSize = max(1, min(maximumFileSize, Self.maximumFileSize))
        self.write = write
    }

    func load(now: Date = Date()) -> MetricHistorySnapshot {
        guard !isLoaded else { return cached }
        isLoaded = true

        do {
            if let data = try BoundedMonitoringFile.read(url, maximumBytes: maximumFileSize) {
                let decoded = try JSONDecoder().decode(MetricHistorySnapshot.self, from: data)
                guard decoded.version == MetricHistorySnapshot.currentVersion,
                      (decoded.telemetry + decoded.memoryTelemetry).allSatisfy({
                          ($0.temperatureReadings?.count ?? 0) <= 64 && ($0.fanReadings?.count ?? 0) <= 64
                      }) else {
                    throw MonitoringFileError.invalidStructure
                }
                cached = Self.sanitized(decoded, now: now)
                return cached
            }
        } catch {
            // Preserve the original byte-for-byte. New observations stay in the
            // bounded live buffer; never replace an unreadable file with empty data.
            loadFailure = String(describing: error)
            return cached
        }

        guard let legacyPowerURL else { return cached }
        let legacyPower = MenuBarPowerHistoryStore.load(from: legacyPowerURL, now: now)
        guard !legacyPower.isEmpty else { return cached }
        cached.power = legacyPower
        markDirtyAndPersistIfNeeded(now: now)
        return cached
    }

    func appendTelemetry(_ point: MenuBarTelemetryPoint, now: Date = Date()) {
        _ = load(now: now)
        guard Self.isValid(point, now: now) else { return }
        Self.appendOrdered(point, to: &cached.telemetry, date: \.date)
        markDirtyAndPersistIfNeeded(now: now)
    }

    func appendMemoryTelemetry(
        _ point: MenuBarTelemetryPoint,
        now: Date = Date()
    ) {
        _ = load(now: now)
        guard Self.isValid(point, now: now) else { return }
        Self.appendOrdered(point, to: &cached.memoryTelemetry, date: \.date)
        markDirtyAndPersistIfNeeded(now: now)
    }

    func appendDiskIO(_ point: NativeDiskIOPoint, now: Date = Date()) {
        _ = load(now: now)
        guard Self.isValid(point, now: now) else { return }
        Self.appendOrdered(point, to: &cached.diskIO, date: \.date)
        markDirtyAndPersistIfNeeded(now: now)
    }

    func appendPower(_ point: MenuBarPowerHistoryPoint, now: Date = Date()) {
        _ = load(now: now)
        guard Self.isValid(point, now: now) else { return }
        Self.appendOrdered(point, to: &cached.power, date: \.date)
        markDirtyAndPersistIfNeeded(now: now)
    }

    func flush(now: Date = Date()) async throws {
        _ = load(now: now)
        let requestedRevision = revision
        while isDirty && persistedRevision < requestedRevision {
            guard loadFailure == nil else { throw MetricHistoryStoreError.preservedUnreadableHistory }
            if let saveTask {
                await saveTask.value
                if let lastPersistenceError { throw lastPersistenceError }
            } else if let task = scheduleSave(now: now, force: true) {
                await task.value
                if let lastPersistenceError { throw lastPersistenceError }
            } else {
                throw lastPersistenceError ?? MetricHistoryStoreError.retryDeferred
            }
        }
    }

    private func markDirtyAndPersistIfNeeded(now: Date) {
        isDirty = true
        revision &+= 1
        latestMutationAt = now
        _ = scheduleSave(now: now, force: false)
    }

    /// The actor continues accepting bounded retained history while ONE worker
    /// encodes/writes an immutable snapshot. Cached history is also the latest
    /// pending state; there is no queue of full documents or write tasks.
    private func scheduleSave(now: Date, force: Bool) -> Task<Void, Never>? {
        guard saveTask == nil, loadFailure == nil,
              saveSchedule.begin(at: now, interval: Self.saveInterval, force: force) else { return nil }
        let snapshot = cached
        let savedRevision = revision
        let limit = maximumFileSize
        let destination = url
        let write = self.write
        let worker = Task.detached(priority: .utility) {
            var document = Self.persistable(snapshot, longRangeBucket: 5 * 60)
            var data = try JSONEncoder().encode(document)
            if data.count > limit {
                document = Self.persistable(snapshot, longRangeBucket: 30 * 60)
                data = try JSONEncoder().encode(document)
            }
            guard data.count <= limit else { throw MetricHistoryStoreError.fileTooLarge }
            try write(data, destination)
        }
        let task = Task {
            let result = await worker.result
            // Use the newest observed clock value to prevent a slow write from
            // immediately replaying a backlog of historical save deadlines.
            let completedAt = max(now, latestMutationAt)
            switch result {
            case .success:
                persistedRevision = savedRevision
                isDirty = revision != savedRevision
                saveSchedule.succeeded(at: completedAt)
                lastPersistenceError = nil
            case .failure(let error):
                saveSchedule.failed(at: completedAt)
                lastPersistenceError = error
            }
            saveTask = nil
        }
        saveTask = task
        return task
    }

    var isSaveInFlight: Bool { saveTask != nil }

    private static func sanitized(
        _ snapshot: MetricHistorySnapshot,
        now: Date
    ) -> MetricHistorySnapshot {
        MetricHistorySnapshot(
            telemetry: retained(snapshot.telemetry, now: now, date: \.date) {
                isValid($0, now: now)
            },
            memoryTelemetry: retained(
                snapshot.memoryTelemetry,
                now: now,
                date: \.date
            ) {
                isValid($0, now: now)
            },
            diskIO: retained(snapshot.diskIO, now: now, date: \.date) {
                isValid($0, now: now)
            },
            power: retained(snapshot.power, now: now, date: \.date) {
                isValid($0, now: now)
            }
        )
    }

    private static func retained<T>(
        _ points: [T],
        now: Date,
        date: KeyPath<T, Date>,
        isValid: (T) -> Bool
    ) -> [T] {
        let cutoff = now.addingTimeInterval(-MenuBarHistoryRetention.duration)
        let ordered = points.enumerated().sorted {
            let lhs = $0.element[keyPath: date]
            let rhs = $1.element[keyPath: date]
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }
        var result: [T] = []
        for point in ordered.map(\.element)
        where point[keyPath: date] >= cutoff && isValid(point) {
            MenuBarHistoryRetention.append(point, to: &result, date: date)
        }
        return result
    }

    private static func appendOrdered<T>(
        _ point: T,
        to points: inout [T],
        date: KeyPath<T, Date>
    ) {
        guard let lastDate = points.last?[keyPath: date],
              point[keyPath: date] < lastDate else {
            MenuBarHistoryRetention.append(point, to: &points, date: date)
            return
        }

        let ordered = (points + [point]).enumerated().sorted {
            let lhs = $0.element[keyPath: date]
            let rhs = $1.element[keyPath: date]
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }
        points.removeAll(keepingCapacity: true)
        for value in ordered.map(\.element) {
            MenuBarHistoryRetention.append(value, to: &points, date: date)
        }
    }

    private static func persistable(
        _ snapshot: MetricHistorySnapshot,
        longRangeBucket: TimeInterval
    ) -> MetricHistorySnapshot {
        MetricHistorySnapshot(
            telemetry: multiresolution(
                snapshot.telemetry,
                date: \.date,
                longRangeBucket: longRangeBucket
            ),
            memoryTelemetry: multiresolution(
                snapshot.memoryTelemetry,
                date: \.date,
                longRangeBucket: longRangeBucket
            ),
            diskIO: multiresolution(
                snapshot.diskIO,
                date: \.date,
                longRangeBucket: longRangeBucket
            ),
            power: multiresolution(
                snapshot.power,
                date: \.date,
                longRangeBucket: longRangeBucket
            )
        )
    }

    /// Keep raw recent samples, minute samples for the current day, and the
    /// newest real sample in each deterministic long-range bucket after that.
    private static func multiresolution<T>(
        _ points: [T],
        date: KeyPath<T, Date>,
        longRangeBucket: TimeInterval
    ) -> [T] {
        guard let end = points.last?[keyPath: date] else { return [] }
        let highResolutionCutoff = end.addingTimeInterval(
            -MenuBarHistoryRetention.highResolutionDuration
        )
        let dailyCutoff = end.addingTimeInterval(-24 * 60 * 60)
        var result: [T] = []
        var lastBucketDuration: TimeInterval?
        var lastBucketIndex: Int64?

        for point in points {
            let pointDate = point[keyPath: date]
            if pointDate >= highResolutionCutoff {
                lastBucketDuration = nil
                lastBucketIndex = nil
                result.append(point)
                continue
            }
            let bucketDuration = pointDate >= dailyCutoff
                ? MenuBarHistoryRetention.bucketDuration
                : longRangeBucket
            let bucket = Int64(floor(
                pointDate.timeIntervalSinceReferenceDate / bucketDuration
            ))
            if bucketDuration == lastBucketDuration,
               bucket == lastBucketIndex {
                result[result.count - 1] = point
            } else {
                result.append(point)
            }
            lastBucketDuration = bucketDuration
            lastBucketIndex = bucket
        }
        return result
    }

    private static func isValid(_ point: MenuBarTelemetryPoint, now: Date) -> Bool {
        isValidDate(point.date, now: now)
            && [
                point.cpuTotal,
                point.cpuUser,
                point.cpuSystem,
                point.gpu,
                point.chipTemperature,
                point.gpuTemperature,
                point.fanRPM,
            ].allSatisfy { $0.map { $0.isFinite && $0 >= 0 } ?? true }
            && point.memory.map { $0.isFinite && (0...100).contains($0) } ?? true
            && point.memoryPressure.map {
                $0.isFinite && (0...100).contains($0)
            } ?? true
            && point.downBytesPerSecond.map { $0 >= 0 } ?? true
            && point.upBytesPerSecond.map { $0 >= 0 } ?? true
            && point.temperatureReadings.map { readings in
                readings.count <= SystemTemperatureZone.allCases.count
                    && Set(readings.map(\.zone)).count == readings.count
                    && readings.allSatisfy {
                        $0.celsius.isFinite && (5...130).contains($0.celsius)
                    }
            } ?? true
            && point.fanReadings?.allSatisfy {
                $0.actualRPM >= 0
                    && $0.minimumRPM.map { $0 >= 0 } ?? true
                    && $0.maximumRPM.map { $0 >= 0 } ?? true
                    && $0.targetRPM.map { $0 >= 0 } ?? true
            } ?? true
    }

    private static func isValid(_ point: NativeDiskIOPoint, now: Date) -> Bool {
        isValidDate(point.date, now: now)
            && point.readBytesPerSecond >= 0
            && point.writeBytesPerSecond >= 0
            && point.readOperationsPerSecond.isFinite
            && point.readOperationsPerSecond >= 0
            && point.writeOperationsPerSecond.isFinite
            && point.writeOperationsPerSecond >= 0
    }

    private static func isValid(_ point: MenuBarPowerHistoryPoint, now: Date) -> Bool {
        isValidDate(point.date, now: now)
            && point.chargePercent.map { $0.isFinite && (0...100).contains($0) } ?? true
            && point.batteryPowerWatts.map(\.isFinite) ?? true
    }

    private static func isValidDate(_ date: Date, now: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
            && date >= now.addingTimeInterval(-MenuBarHistoryRetention.duration)
            && date <= now.addingTimeInterval(futureTolerance)
    }
}

/// Legacy reader/writer retained only for one-way migration and old tests.
enum MenuBarPowerHistoryStore {
    static let saveInterval: TimeInterval = 5 * 60
    private static let maximumArchivedPointCount = 360

    static var defaultURL: URL? {
        guard let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return applicationSupport
            .appendingPathComponent("com.local.StorageCleanerMac", isDirectory: true)
            .appendingPathComponent("MenuBarPowerHistory.json")
    }

    static func load(from url: URL, now: Date = Date()) -> [MenuBarPowerHistoryPoint] {
        guard let data = try? BoundedMonitoringFile.read(url, maximumBytes: MetricHistoryStore.maximumFileSize),
              let decoded = try? JSONDecoder().decode(
                  BoundedMonitoringArray<MenuBarPowerHistoryPoint>.self,
                  from: data
              ).values else { return [] }

        let cutoff = now.addingTimeInterval(-MenuBarHistoryRetention.duration)
        let futureLimit = now.addingTimeInterval(5 * 60)
        var retained: [MenuBarPowerHistoryPoint] = []
        for point in decoded.sorted(by: { $0.date < $1.date })
        where point.date >= cutoff && point.date <= futureLimit {
            MenuBarHistoryRetention.append(point, to: &retained, date: \.date)
        }
        return retained
    }

    static func save(_ points: [MenuBarPowerHistoryPoint], to url: URL) throws {
        let data = try JSONEncoder().encode(persistablePoints(points))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func persistablePoints(
        _ points: [MenuBarPowerHistoryPoint]
    ) -> [MenuBarPowerHistoryPoint] {
        guard let end = points.last?.date else { return [] }
        let recentCutoff = end.addingTimeInterval(
            -MenuBarHistoryRetention.highResolutionDuration
        )
        let recentStart = points.firstIndex { $0.date >= recentCutoff }
            ?? points.endIndex
        let older = Array(points[..<recentStart])
        let recent = Array(points[recentStart...])
        let selectedOlder = MenuBarHistoryRetention.selected(
            older,
            duration: MenuBarHistoryRetention.duration,
            date: \.date,
            referenceDate: end
        )
        guard selectedOlder.count > maximumArchivedPointCount else {
            return selectedOlder + recent
        }

        let windowStart = end.addingTimeInterval(-MenuBarHistoryRetention.duration)
        let bucketDuration = MenuBarHistoryRetention.duration
            / Double(maximumArchivedPointCount)
        var archived: [MenuBarPowerHistoryPoint] = []
        var previousBucket: Int?
        for point in selectedOlder {
            let bucket = min(
                maximumArchivedPointCount - 1,
                max(0, Int(point.date.timeIntervalSince(windowStart) / bucketDuration))
            )
            if bucket == previousBucket {
                archived[archived.count - 1] = point
            } else {
                archived.append(point)
                previousBucket = bucket
            }
        }
        return archived + recent
    }
}
