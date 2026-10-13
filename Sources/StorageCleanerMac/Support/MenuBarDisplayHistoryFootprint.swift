import Foundation

/// D39: the memory held by the history windows kept while the panel is
/// hidden, counted from their buffers (the process footprint is dominated by
/// allocator caches and cannot show a difference of this size).
struct MenuBarDisplayHistoryFootprint: Equatable, Sendable {
    var windows = 0
    var points = 0
    /// The window arrays' own buffers: array header plus capacity × point
    /// stride, rounded up to malloc's 16-byte quantum.
    var arrayBytes = 0
    /// Buffers of the per-point reading arrays (temperatures, fans). The
    /// window points are copies of history points, so these buffers are
    /// normally shared with the full history and not held a second time;
    /// counted as an upper bound.
    var sharedReadingBytes = 0

    /// A Swift array buffer's header on 64-bit platforms: object header,
    /// count and capacity.
    static let arrayHeaderBytes = 32

    static func of(_ windows: [[MenuBarTelemetryPoint]]) -> Self {
        var footprint = Self()
        for window in windows where !window.isEmpty {
            footprint.windows += 1
            footprint.points += window.count
            footprint.arrayBytes += buffer(capacity: window.capacity, stride: MemoryLayout<MenuBarTelemetryPoint>.stride)
            for point in window {
                if let readings = point.temperatureReadings, !readings.isEmpty {
                    footprint.sharedReadingBytes += buffer(capacity: readings.capacity,
                                                           stride: MemoryLayout<SystemTemperatureReading>.stride)
                }
                if let fans = point.fanReadings, !fans.isEmpty {
                    footprint.sharedReadingBytes += buffer(capacity: fans.capacity,
                                                           stride: MemoryLayout<SystemFanReading>.stride)
                }
            }
        }
        return footprint
    }

    private static func buffer(capacity: Int, stride: Int) -> Int {
        (arrayHeaderBytes + capacity * stride + 15) / 16 * 16
    }
}
