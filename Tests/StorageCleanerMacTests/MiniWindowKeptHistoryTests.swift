import Foundation
import XCTest
@testable import StorageCleanerMac

/// D39 (user-approved): the panel keeps the last visible demand's prepared
/// history windows while it is hidden and draws them at once when it opens
/// again (marked as updating until replaced); readings shown as "now" use
/// the live snapshot while the history is not prepared or is such a kept
/// window, so the CPU total no longer shows "—" right after opening.
@MainActor
final class MiniWindowKeptHistoryTests: XCTestCase {
    private func point(_ seconds: TimeInterval, cpu: Double, readings: Bool = false) -> MenuBarTelemetryPoint {
        MenuBarTelemetryPoint(
            date: Date(timeIntervalSince1970: 1_000_000 + seconds),
            cpuTotal: cpu, cpuUser: cpu * 0.75, cpuSystem: cpu * 0.25, gpu: nil, memory: 50,
            chipTemperature: 45,
            temperatureReadings: readings ? [SystemTemperatureReading(zone: .chip, celsius: 45),
                                             SystemTemperatureReading(zone: .gpu, celsius: 40)] : nil,
            fanRPM: nil, downBytesPerSecond: 10, upBytesPerSecond: 5
        )
    }

    func testTheCurrentReadingIsLiveUntilTheDrawnHistoryIsCurrent() {
        let live = point(100, cpu: 12)
        let history = [point(10, cpu: 70), point(20, cpu: 71)]
        let current = MenuBarDisplayedHistory(points: history, range: .oneHour, isUpdating: false)
        XCTAssertEqual(current.currentReading(live: live)?.cpuTotal, 71, "a current history: its last point, as drawn")

        let kept = MenuBarDisplayedHistory(points: history, range: .oneHour, isUpdating: true)
        XCTAssertEqual(kept.currentReading(live: live)?.cpuTotal, 12,
                       "a kept or previous window: the live reading, not one from before")
        XCTAssertEqual(kept.currentReading(live: nil)?.cpuTotal, 71, "without a live reading the window still answers")

        let empty = MenuBarDisplayedHistory(points: [], range: .oneHour, isUpdating: false)
        XCTAssertEqual(empty.currentReading(live: live)?.cpuTotal, 12, "not prepared yet: the live reading, not —")
        XCTAssertNil(empty.currentReading(live: nil)?.cpuTotal)
    }

    func testTheCPUCardTotalUsesTheCurrentReading() {
        XCTAssertEqual(GeekProcessorPresentation.totalText(history: [], current: point(1, cpu: 12)), "12%")
        XCTAssertEqual(GeekProcessorPresentation.totalText(history: [point(1, cpu: 70)], current: nil), "70%",
                       "previews without a live reading keep the history's last point")
        XCTAssertEqual(GeekProcessorPresentation.totalText(history: [], current: nil), "—")
    }

    func testTheKeptWindowsAreCountedFromTheirBuffers() {
        let stride = MemoryLayout<MenuBarTelemetryPoint>.stride
        var window: [MenuBarTelemetryPoint] = []
        window.reserveCapacity(10)
        window.append(contentsOf: (0..<10).map { point(Double($0), cpu: 10, readings: $0 < 4) })
        let footprint = MenuBarDisplayHistoryFootprint.of([window, []])
        XCTAssertEqual(footprint.windows, 1, "empty windows hold no buffer")
        XCTAssertEqual(footprint.points, 10)
        XCTAssertEqual(footprint.arrayBytes, (32 + window.capacity * stride + 15) / 16 * 16)
        let readingStride = MemoryLayout<SystemTemperatureReading>.stride
        XCTAssertEqual(footprint.sharedReadingBytes, 4 * ((32 + 2 * readingStride + 15) / 16 * 16))
    }
}
