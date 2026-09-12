import Foundation

struct CapacityHistoryPoint: Codable, Equatable, Sendable {
    let recordedAt: Date
    let totalBytes: Int64
    let availableBytes: Int64
    let availableForImportantUsageBytes: Int64?
    let dayKey: String
    let segmentID: Int

    init(
        recordedAt: Date,
        totalBytes: Int64,
        availableBytes: Int64,
        availableForImportantUsageBytes: Int64?,
        dayKey: String = "",
        segmentID: Int = 0
    ) {
        self.recordedAt = recordedAt
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
        self.dayKey = dayKey
        self.segmentID = segmentID
    }
}

enum CapacityHistoryStorage: Equatable, Sendable {
    case memory
    case file(URL)
}

protocol CapacityHistoryPersisting: Sendable {
    func save(_ point: CapacityHistoryPoint) async throws
}

actor CapacityHistoryRepository: CapacityHistoryPersisting {
    private let service: CapacityHistoryService

    init(
        storage: CapacityHistoryStorage = .file(CapacityHistoryService.defaultStorageURL),
        calendar: Calendar = .current
    ) {
        self.service = CapacityHistoryService(storage: storage, calendar: calendar)
    }

    func save(_ point: CapacityHistoryPoint) async throws {
        try service.record(point)
    }
}

final class CapacityHistoryService {
    static let maximumPointCount = 90
    static let defaultStorageURL: URL = {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("capacity-history.json", isDirectory: false)
    }()

    private let storage: CapacityHistoryStorage
    private let calendar: Calendar
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var memoryPoints = [CapacityHistoryPoint]()

    init(
        storage: CapacityHistoryStorage = .file(CapacityHistoryService.defaultStorageURL),
        calendar: Calendar = .current
    ) {
        self.storage = storage
        self.calendar = calendar
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func record(_ point: CapacityHistoryPoint) throws {
        guard isValid(point) else { return }

        guard let points = adding(point, to: try load()) else { return }
        try persist(points)
    }

    func load() throws -> [CapacityHistoryPoint] {
        let decoded: [CapacityHistoryPoint]
        switch storage {
        case .memory:
            decoded = memoryPoints
        case let .file(url):
            guard let data = try? Data(contentsOf: url),
                  let points = try? decoder.decode([CapacityHistoryPoint].self, from: data) else {
                return []
            }
            decoded = points
        }
        return sanitized(decoded)
    }

    func trendSnapshot() throws -> CapacityTrendSnapshot {
        try trendSnapshot(including: nil)
    }

    func trendSnapshot(
        including point: CapacityHistoryPoint?
    ) throws -> CapacityTrendSnapshot {
        var points = try load()
        if let point,
           isValid(point),
           let merged = adding(point, to: points)
        {
            points = merged
        }
        return trendSnapshot(from: points, fallbackDate: point?.recordedAt ?? Date())
    }

    private func trendSnapshot(
        from points: [CapacityHistoryPoint],
        fallbackDate: Date
    ) -> CapacityTrendSnapshot {
        guard let latest = points.last else {
            return CapacityTrendSnapshot(
                availability: .unavailable,
                status: .unavailable,
                totalBytes: nil,
                availableBytes: nil,
                availableForImportantUsageBytes: nil,
                sevenDayDeltaBytes: nil,
                thirtyDayDeltaBytes: nil,
                recordedAt: fallbackDate
            )
        }

        let currentSegmentPoints = points.filter { $0.segmentID == latest.segmentID }
        let pressure = StorageCapacitySnapshot(
            totalBytes: latest.totalBytes,
            availableBytes: latest.availableBytes,
            availableForImportantUsageBytes: latest.availableForImportantUsageBytes
        ).pressure
        let status: HealthStatus = switch pressure {
        case .normal:
            .healthy
        case .attention:
            .attention
        case .critical:
            .actionRequired
        }

        return CapacityTrendSnapshot(
            availability: .available,
            status: status,
            totalBytes: latest.totalBytes,
            availableBytes: latest.availableBytes,
            availableForImportantUsageBytes: latest.availableForImportantUsageBytes,
            sevenDayDeltaBytes: delta(
                days: 7,
                latest: latest,
                points: currentSegmentPoints
            ),
            thirtyDayDeltaBytes: delta(
                days: 30,
                latest: latest,
                points: currentSegmentPoints
            ),
            recordedAt: latest.recordedAt
        )
    }

    private func adding(
        _ point: CapacityHistoryPoint,
        to existingPoints: [CapacityHistoryPoint]
    ) -> [CapacityHistoryPoint]? {
        var points = existingPoints
        if let latest = points.last, latest.recordedAt > point.recordedAt {
            return nil
        }
        let incomingDayKey = dayKey(for: point.recordedAt)
        points.removeAll { $0.dayKey == incomingDayKey }
        let latestCurrentPoint = points.last
        let currentSegment = latestCurrentPoint?.segmentID ?? 0
        let startsNewSegment = latestCurrentPoint.map {
            totalCapacityChangedByMoreThanFivePercent(
                from: $0.totalBytes,
                to: point.totalBytes
            )
        } ?? false
        let segmentID = startsNewSegment ? currentSegment + 1 : currentSegment
        points.append(normalized(point, segmentID: segmentID))
        points.sort { lhs, rhs in
            if lhs.recordedAt == rhs.recordedAt {
                return lhs.dayKey < rhs.dayKey
            }
            return lhs.recordedAt < rhs.recordedAt
        }
        if points.count > Self.maximumPointCount {
            points = Array(points.suffix(Self.maximumPointCount))
        }
        return points
    }

    private func persist(_ points: [CapacityHistoryPoint]) throws {
        switch storage {
        case .memory:
            memoryPoints = points
        case let .file(url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(points)
            try data.write(to: url, options: .atomic)
        }
    }

    private func sanitized(_ points: [CapacityHistoryPoint]) -> [CapacityHistoryPoint] {
        var latestByDay = [String: CapacityHistoryPoint]()
        for point in points where isValid(point) && point.segmentID >= 0 {
            let normalized = normalized(point, segmentID: point.segmentID)
            if let existing = latestByDay[normalized.dayKey],
               existing.recordedAt > normalized.recordedAt {
                continue
            }
            latestByDay[normalized.dayKey] = normalized
        }
        let sorted = latestByDay.values.sorted { lhs, rhs in
            if lhs.recordedAt == rhs.recordedAt {
                return lhs.dayKey < rhs.dayKey
            }
            return lhs.recordedAt < rhs.recordedAt
        }
        let bounded = Array(sorted.suffix(Self.maximumPointCount))
        var previousSegmentID: Int?
        var normalizedSegmentID = 0
        return bounded.map { point in
            if let previousSegmentID, previousSegmentID != point.segmentID {
                normalizedSegmentID += 1
            }
            previousSegmentID = point.segmentID
            return normalized(point, segmentID: normalizedSegmentID)
        }
    }

    private func normalized(_ point: CapacityHistoryPoint, segmentID: Int) -> CapacityHistoryPoint {
        CapacityHistoryPoint(
            recordedAt: point.recordedAt,
            totalBytes: point.totalBytes,
            availableBytes: point.availableBytes,
            availableForImportantUsageBytes: point.availableForImportantUsageBytes,
            dayKey: dayKey(for: point.recordedAt),
            segmentID: segmentID
        )
    }

    private func isValid(_ point: CapacityHistoryPoint) -> Bool {
        guard point.recordedAt.timeIntervalSinceReferenceDate.isFinite,
              point.totalBytes > 0,
              point.availableBytes >= 0,
              point.availableBytes <= point.totalBytes else {
            return false
        }
        if let important = point.availableForImportantUsageBytes,
           important < 0 || important > point.totalBytes {
            return false
        }
        return true
    }

    private func totalCapacityChangedByMoreThanFivePercent(
        from previous: Int64,
        to current: Int64
    ) -> Bool {
        guard previous > 0, current > 0 else { return true }
        let difference = abs(Double(current) - Double(previous))
        return difference / Double(previous) > 0.05
    }

    private func delta(
        days: Int,
        latest: CapacityHistoryPoint,
        points: [CapacityHistoryPoint]
    ) -> Int64? {
        guard let targetDate = calendar.date(
            byAdding: .day,
            value: -days,
            to: latest.recordedAt
        ) else {
            return nil
        }
        let targetDayKey = dayKey(for: targetDate)
        guard let reference = points.first(where: { $0.dayKey == targetDayKey }) else {
            return nil
        }
        let (delta, overflow) = latest.availableBytes.subtractingReportingOverflow(reference.availableBytes)
        return overflow ? nil : delta
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return "invalid"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
