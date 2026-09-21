import Darwin
import Foundation

/// Ordinary monitoring only. Never used by operation/recovery journals.
struct MonitoringSaveSchedule: Sendable {
    private(set) var lastAttempt: Date?
    private(set) var lastSuccess: Date?
    private(set) var nextRetry: Date?
    private(set) var failures = 0

    mutating func begin(at now: Date, interval: TimeInterval, force: Bool) -> Bool {
        // Clock rollback must not defer monitoring indefinitely.
        if let lastAttempt, now < lastAttempt { nextRetry = nil; lastSuccess = nil }
        if let nextRetry, now < nextRetry { return false }
        if !force, let lastSuccess, now.timeIntervalSince(lastSuccess) < interval { return false }
        lastAttempt = now
        return true
    }

    mutating func succeeded(at now: Date) {
        lastSuccess = now
        nextRetry = nil
        failures = 0
    }

    mutating func failed(at now: Date) {
        failures = min(failures + 1, 5)
        nextRetry = now.addingTimeInterval(min(300, 30 * pow(2, Double(failures - 1))))
    }
}

enum MonitoringFileError: Error, Equatable {
    case invalidType, oversized, changedDuringRead, invalidStructure, unavailable(Int32)
}

enum BoundedMonitoringFile {
    /// Reject final-component symlinks and non-regular files. Read from the
    /// validated descriptor with a hard byte limit, including concurrent growth.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw MonitoringFileError.unavailable(errno)
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw MonitoringFileError.invalidType
        }
        guard maximumBytes > 0, before.st_size >= 0, before.st_size <= maximumBytes else {
            throw MonitoringFileError.oversized
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: min(65_536, maximumBytes + 1))
        while true {
            let limit = min(buffer.count, maximumBytes - data.count + 1)
            let count = Darwin.read(fd, &buffer, limit)
            if count < 0 {
                if errno == EINTR { continue }
                throw MonitoringFileError.unavailable(errno)
            }
            if count == 0 { break }
            guard count <= maximumBytes - data.count else { throw MonitoringFileError.oversized }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == before.st_size,
              data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw MonitoringFileError.changedDuringRead
        }
        return data
    }
}

/// Bounds container growth during decoding, rather than after allocating an
/// arbitrary array. The file byte cap separately bounds per-record complexity.
struct BoundedMonitoringArray<Element: Decodable>: Decodable {
    static var maximumCount: Int { 60_000 }
    let values: [Element]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if let count = container.count, count > Self.maximumCount { throw MonitoringFileError.invalidStructure }
        var result: [Element] = []
        while !container.isAtEnd {
            guard result.count < Self.maximumCount else { throw MonitoringFileError.invalidStructure }
            result.append(try container.decode(Element.self))
        }
        values = result
    }
}
