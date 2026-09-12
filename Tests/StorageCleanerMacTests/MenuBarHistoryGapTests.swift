import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

final class MenuBarHistoryGapTests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 100_000)
    private let plot = CGRect(x: 0, y: 0, width: 360, height: 100)

    private func point(_ second: Int, value: Double?) -> MenuBarTelemetryPoint {
        .init(date: end.addingTimeInterval(Double(second)), cpuTotal: value,
              cpuUser: value.map { $0 * 0.75 }, cpuSystem: value.map { $0 * 0.25 },
              gpu: nil, memory: value, chipTemperature: nil, fanRPM: nil,
              downBytesPerSecond: value.map { Int64($0 * 100) },
              upBytesPerSecond: value.map { Int64($0 * 10) })
    }

    @MainActor
    func testLongMemoryHistoryPreparationDoesNotRepeatedlyScanTheEntireSeries() {
        let points = (-5000 ... -1).map { point($0, value: 0.64) }
        let chart = GeekPrecisionLineChart(points: points,
            series: [.init(id: "memory", title: "Memory", channel: .memory, color: .purple)],
            valueRange: 0...1, unit: .percent, accessibilityLabel: "Memory",
            style: .stackedBars, duration: 7200)
        let clock = ContinuousClock()
        let start = clock.now
        let segments = chart.pointSegments(for: .memory, in: plot,
            valueRange: 0...1, referenceDate: end)
        XCTAssertFalse(segments.isEmpty)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(5),
            "A long memory history must resolve visible series once, not once per sample")
    }

    func testFreshTailWaitsForNextPollButStopsOnStaleFailedOrPausedSampling() {
        let dates = (-31 ... -1).map { end.addingTimeInterval(Double($0)) }
        func buckets(at reference: Date, valid: Bool = true, gaps: [DateInterval] = []) -> [GeekChartBucketSnapshot] {
            GeekChartWindow.displayBuckets(for: dates, in: plot,
                range: (reference.addingTimeInterval(-30), reference, dates[0]),
                referenceDate: reference, displayScale: 2,
                isValid: { valid || $0 != dates.count - 1 },
                unrecordedIntervals: gaps, holdLatestWhileFresh: true)
        }
        XCTAssertTrue(buckets(at: end).allSatisfy { !$0.indices.isEmpty })
        XCTAssertEqual(buckets(at: end).last?.indices, [dates.count - 1])
        XCTAssertEqual(buckets(at: end).last?.isEstimated, true)
        XCTAssertEqual(buckets(at: end.addingTimeInterval(1)).last?.indices, [])
        XCTAssertEqual(buckets(at: end, valid: false).last?.indices, [])
        let pause = DateInterval(start: end.addingTimeInterval(-0.75), end: end)
        XCTAssertEqual(buckets(at: end, gaps: [pause]).last?.indices, [])
    }

    func testLiveCPUAndNetworkKeepUniformColumnsBetweenNormalPolls() {
        let points = (-31 ... -1).map { point($0, value: 20) }
        let original = points
        let cpu = GeekCPUHistoryFrame.prepare(points: points, plotRect: plot,
            duration: 30, referenceDate: end, samplingInterval: 1, displayScale: 2)
        XCTAssertEqual(cpu.marks.count, 120)
        XCTAssertTrue(cpu.marks.last?.isEstimated == true)
        XCTAssertEqual(Set(cpu.marks.map { $0.rect.width }).count, 1)
        let network = GeekPreparedNetworkFrame(history: GeekNetworkHistorySnapshot(points: points),
            plotRect: plot, duration: 30, referenceDate: end, displayScale: 2)
        XCTAssertEqual(network.uploadMarks.count, 120)
        XCTAssertEqual(network.downloadMarks.count, 120)
        XCTAssertEqual(network.buckets.last?.upload, 200)
        XCTAssertEqual(network.buckets.last?.uploadIsEstimated, true)
        XCTAssertEqual(points, original)
    }

    func testSingleFailedCPUPollReconstructsDisplayWithoutChangingHistory() {
        let points = (-31...0).map { point($0, value: $0 == -15 ? nil : 20) }
        let original = points
        let frame = GeekCPUHistoryFrame.prepare(points: points, plotRect: plot,
            duration: 30, referenceDate: end, samplingInterval: 1, displayScale: 2)
        XCTAssertEqual(frame.marks.count, 120)
        XCTAssertTrue(frame.marks.contains(where: \.isEstimated))
        XCTAssertTrue(frame.marks.allSatisfy { $0.mean.cpuTotal == 20 })
        XCTAssertEqual(points, original)
        XCTAssertNil(points.first { $0.date == end.addingTimeInterval(-15) }?.cpuTotal)
        XCTAssertEqual(Set(frame.marks.map { $0.rect.width }).count, 1)
    }

    func testMemoryShortFailureIsEstimatedButSleepAndLongFailureStayEmpty() {
        let dates = (-31...0).map { end.addingTimeInterval(Double($0)) }
        let failed = Set([16]) // -15 s
        func buckets(_ failures: Set<Int>, gaps: [DateInterval] = []) -> [GeekChartBucketSnapshot] {
            GeekChartWindow.displayBuckets(for: dates, in: plot,
                range: (end.addingTimeInterval(-30), end, dates[0]),
                referenceDate: end, displayScale: 2,
                isValid: { !failures.contains($0) }, isMissing: { failures.contains($0) },
                unrecordedIntervals: gaps)
        }
        let recovered = buckets(failed)
        XCTAssertTrue(recovered.allSatisfy { !$0.indices.isEmpty && !$0.indices.contains(16) })
        XCTAssertTrue(recovered.contains(where: \.isEstimated))
        let paused = buckets(failed, gaps: [.init(start: end.addingTimeInterval(-16), end: end.addingTimeInterval(-14))])
        XCTAssertTrue(paused.contains { $0.indices == [16] || $0.indices.isEmpty })
        let longFailure = buckets(Set(11...21))
        XCTAssertTrue(longFailure[60].indices.isEmpty || longFailure[60].indices.allSatisfy { (11...21).contains($0) })
        XCTAssertFalse(longFailure[60].isEstimated)
    }

    func testNetworkShortFailureRecoversBothDirectionsAndPreservesRawStatistics() {
        let points = (-31...0).map { point($0, value: $0 == -15 ? nil : 20) }
        let history = GeekNetworkHistorySnapshot(points: points)
        let frame = GeekPreparedNetworkFrame(history: history, plotRect: plot,
            duration: 30, referenceDate: end, displayScale: 2)
        XCTAssertEqual(frame.uploadMarks.count, 120)
        XCTAssertEqual(frame.downloadMarks.count, 120)
        XCTAssertTrue(frame.buckets.contains { $0.uploadIsEstimated && $0.downloadIsEstimated })
        XCTAssertEqual(history.uploadStatistics?.average, 200)
        XCTAssertEqual(history.downloadStatistics?.average, 2000)
        XCTAssertEqual(history.uploadSamples.filter { $0.value == nil }.count, 1)
    }

    func testPartialNetworkReadingIsNotReplacedByAnEstimate() {
        var points = (-31...0).map { point($0, value: 20) }
        points[16] = .init(date: points[16].date, cpuTotal: nil, cpuUser: nil, cpuSystem: nil,
                          gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil,
                          downBytesPerSecond: nil, upBytesPerSecond: 999)
        let frame = GeekPreparedNetworkFrame(history: .init(points: points), plotRect: plot,
            duration: 30, referenceDate: end, displayScale: 2)
        XCTAssertTrue(frame.buckets.contains { $0.upload == 999 && $0.download == nil && !$0.uploadIsEstimated })
    }

    func testPreSamplingAndStoppedSamplingAreNotInvented() {
        let dates = (-20 ... -10).map { end.addingTimeInterval(Double($0)) }
        let buckets = GeekChartWindow.displayBuckets(for: dates, in: plot,
            range: (end.addingTimeInterval(-30), end, dates[0]),
            referenceDate: end, displayScale: 2, isMissing: { _ in false }, unrecordedIntervals: [])
        XCTAssertTrue(buckets.prefix(35).allSatisfy { $0.indices.isEmpty })
        XCTAssertTrue(buckets.suffix(35).allSatisfy { $0.indices.isEmpty })
    }

    @MainActor
    func testExportFrozenRealHistoryForVisualReviewWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["SCM_HISTORY_REVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        let history = try JSONDecoder().decode(MetricHistorySnapshot.self,
            from: Data(contentsOf: directory.appendingPathComponent("修改前真实历史.json")))
        let reference = try XCTUnwrap(history.telemetry.last?.date)
        let clock = PanelChartClock(anchor: .init(wallDate: reference, instant: ContinuousClock().now))
        let memory = history.memoryTelemetry.filter { $0.date >= reference.addingTimeInterval(-86_400) }
        let cpu = history.telemetry.filter { $0.date >= reference.addingTimeInterval(-3_600) }
        let network = history.telemetry.filter { $0.date >= reference.addingTimeInterval(-3_600) }
        for dark in [false, true] {
            let content = VStack(alignment: .leading, spacing: 14) {
                Text("真实历史回放 · 修复后").font(.title2.bold())
                Text("固定历史文件，不是实时截图；真实长中断保留空档。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("CPU · 1 小时 · 6 秒平均").font(.headline)
                GeekPrecisionLineChart(points: cpu, series: [
                    .init(id: "user", title: "用户", channel: .cpuUser, color: .blue),
                    .init(id: "system", title: "系统", channel: .cpuSystem, color: .purple)
                ], valueRange: 0...100, unit: .percent, accessibilityLabel: "CPU",
                   style: .stackedBars, duration: 3_600, showsLegend: false).frame(height: 120)
                Text("内存 · 1 天 · 144 秒平均").font(.headline)
                GeekPrecisionLineChart(points: memory, series: [
                    .init(id: "memory", title: "内存", channel: .memory, color: .purple)
                ], valueRange: 0...100, unit: .percent, accessibilityLabel: "内存",
                   style: .stackedBars, duration: 86_400, showsLegend: false).frame(height: 120)
                Text("网络 · 1 小时 · 6 秒平均").font(.headline)
                GeekPrecisionNetworkChart(points: network, accessibilityLabel: "网络", duration: 3600,
                                          showsLegend: false).frame(height: 120)
                Text("磁盘 · 1 小时 · 6 秒平均").font(.headline)
                GeekDiskIOChart(points: history.diskIO.filter { $0.date >= reference.addingTimeInterval(-3600) },
                    accessibilityLabel: "磁盘", duration: 3600, showsLegend: false).frame(height: 120)
                Text("电池 · 1 天 · 144 秒平均").font(.headline)
                GeekPowerHistoryChart(points: history.power.filter { $0.date >= reference.addingTimeInterval(-86400) },
                    metric: .charge, duration: 86400, tint: .green, accessibilityLabel: "电池").frame(height: 120)
            }
            .padding(24).frame(width: 600)
            .background(dark ? Color(nsColor: .init(white: 0.12, alpha: 1)) : .white)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.panelChartClock, clock)
            .environment(\.displayScale, 2)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(dark ? "真实历史回放-深色.png" : "真实历史回放-浅色.png"))

            let ranges = GeekChartRange.allCases.filter { $0.duration >= 3600 }
            let rangeContent = VStack(alignment: .leading, spacing: 12) {
                Text("CPU 全时段 · 同一份真实历史").font(.title2.bold())
                Text("长时段约 600 个平均点；空白处没有历史记录。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ranges) { range in
                    Text("\(range.title) · \(Int(GeekHistoryAveraging.interval(for: range.duration)!)) 秒平均")
                        .font(.headline)
                    GeekPrecisionLineChart(points: history.telemetry.filter {
                        $0.date >= reference.addingTimeInterval(-range.duration)
                    }, series: [
                        .init(id: "user", title: "用户", channel: .cpuUser, color: .blue),
                        .init(id: "system", title: "系统", channel: .cpuSystem, color: .purple)
                    ], valueRange: 0...100, unit: .percent, accessibilityLabel: "CPU",
                        style: .stackedBars, duration: range.duration, showsLegend: false).frame(height: 90)
                }
            }
            .padding(24).frame(width: 600)
            .background(dark ? Color(nsColor: .init(white: 0.12, alpha: 1)) : .white)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.panelChartClock, clock).environment(\.displayScale, 2)
            let rangeRenderer = ImageRenderer(content: rangeContent)
            rangeRenderer.scale = 2
            let rangeBitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(rangeRenderer.cgImage))
            try XCTUnwrap(rangeBitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(dark ? "全时段真实历史-深色.png" : "全时段真实历史-浅色.png"))
        }
    }
}
