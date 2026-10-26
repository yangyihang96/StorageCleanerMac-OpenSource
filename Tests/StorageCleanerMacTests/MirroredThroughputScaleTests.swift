import CoreGraphics
import XCTest
@testable import StorageCleanerMac

/// D117: the halves of a mirrored throughput chart each fit their own peak,
/// never below 1 KiB/s, and fill (value / scale)^0.75 of their half, as iStat
/// Menus 7.30 draws network and disk activity. Single-direction charts keep
/// their own scale and stay linear. D120 (2026-10-18): the scale is the
/// visible peak itself, so the tallest bar of each half reaches its edge;
/// D117 rounded it up to a tier (2 000 → 2 500, 5 000 → 7 500).
final class MirroredThroughputScaleTests: XCTestCase {
    func testBarFractionCompressesMirroredHalvesAndKeepsSingleDirectionLinear() {
        XCTAssertEqual(GeekBarChartScale.throughputFloor, 1_024)
        XCTAssertEqual(GeekBarChartScale.mirroredExponent, 0.75)

        let mirrored = GeekBarChartScale.mirroredExponent
        XCTAssertEqual(GeekBarChartScale.barFraction(value: 256, maximum: 1_024, exponent: mirrored),
                       pow(0.25, 0.75), accuracy: 1e-12)
        XCTAssertEqual(GeekBarChartScale.barFraction(value: 256, maximum: 1_024, exponent: 1), 0.25)
        XCTAssertEqual(GeekBarChartScale.barFraction(value: 4_096, maximum: 1_024, exponent: mirrored), 1)
        XCTAssertEqual(GeekBarChartScale.barFraction(value: .infinity, maximum: 1_024, exponent: mirrored), 1)
        for value in [0, -5, Double.nan] {
            XCTAssertEqual(GeekBarChartScale.barFraction(value: value, maximum: 1_024, exponent: mirrored), 0)
        }
        XCTAssertEqual(GeekBarChartScale.barFraction(value: 10, maximum: 0, exponent: mirrored), 1)
        XCTAssertEqual(GeekBarChartScale.barFraction(value: 10, maximum: .nan, exponent: mirrored), 1)
    }

    func testNetworkHalvesFitTheirOwnPeaks() throws {
        let reference = Date(timeIntervalSinceReferenceDate: 40_000)
        let frame = networkFrame(reference: reference, upload: 2_000, download: 2_000_000)

        XCTAssertEqual(frame.uploadMaximum, 2_000)
        XCTAssertEqual(frame.downloadMaximum, 2_000_000)
        let upload = try XCTUnwrap(frame.uploadMarks.last?.value)
        let download = try XCTUnwrap(frame.downloadMarks.last?.value)
        // One shared scale drew the upload half as a hairline (0.08 %). D117's
        // tier left the peak at 0.85 of its half; D120's fills it.
        XCTAssertEqual(GeekBarChartScale.barFraction(
            value: upload, maximum: frame.uploadMaximum, exponent: GeekBarChartScale.mirroredExponent), 1,
            accuracy: 1e-12)
        XCTAssertEqual(GeekBarChartScale.barFraction(
            value: download, maximum: frame.downloadMaximum, exponent: GeekBarChartScale.mirroredExponent), 1,
            accuracy: 1e-12)
    }

    func testIdleOrMissingDirectionKeepsTheFloor() {
        let reference = Date(timeIntervalSinceReferenceDate: 41_000)
        let idle = networkFrame(reference: reference, upload: 12, download: 0)
        XCTAssertEqual(idle.uploadMaximum, GeekBarChartScale.throughputFloor)
        XCTAssertEqual(idle.downloadMaximum, GeekBarChartScale.throughputFloor)
        XCTAssertLessThan(GeekBarChartScale.barFraction(
            value: 12, maximum: idle.uploadMaximum, exponent: GeekBarChartScale.mirroredExponent), 0.05,
            "12 B/s of background traffic must not fill its half")

        let downloadOnly = networkFrame(reference: reference, upload: nil, download: 5_000)
        XCTAssertEqual(downloadOnly.uploadMaximum, GeekBarChartScale.throughputFloor)
        XCTAssertEqual(downloadOnly.downloadMaximum, 5_000)
    }

    func testDiskHalvesFitTheirOwnPeaks() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let points = (0..<3).map { index in
            NativeDiskIOPoint(
                date: now.addingTimeInterval(Double(index - 2)),
                readBytesPerSecond: 50_000_000,
                writeBytesPerSecond: 3_000,
                readOperationsPerSecond: 2,
                writeOperationsPerSecond: 1
            )
        }
        let frame = GeekPreparedDiskFrame(points: points, plot: CGRect(x: 0, y: 0, width: 240, height: 100),
                                          duration: 120, reference: now, scale: 2)

        XCTAssertEqual(frame.readMaximum, 50_000_000)
        XCTAssertEqual(frame.writeMaximum, 3_000)
    }

    func testMirroredSeriesCompressesOnlyMirroredHalves() throws {
        let series = try chartSection("private struct GeekMirroredBarSeries: View {")
        XCTAssertTrue(series.contains("let exponent = singleDirection ? 1 : GeekBarChartScale.mirroredExponent"))
        XCTAssertTrue(series.contains("value: mark.value, maximum: maximum, exponent: exponent"))
        XCTAssertFalse(series.contains("safeMaximum"), "One bar formula: GeekBarChartScale.barFraction")
    }

    func testEachDirectionDrawsWithItsOwnDecayingScale() throws {
        let network = try chartSection("struct GeekPrecisionNetworkChart: View {")
        // D121 (2026-10-18): the live cards keep easing (`easesScale` is on by
        // default); a history draws each target itself. Were
        // `maximum: \(direction)AxisScale.displayedMaximum(fallback: \(direction)Target)`.
        XCTAssertTrue(network.contains("var easesScale = true"))
        // D130/D131 (2026-10-19): only the projection eases; iStat's sample
        // bars and history buckets draw each target itself. Were
        // `maximum: easesScale ? \(direction)AxisScale.displayedMaximum(…) : \(direction)Target`.
        let eases = "private var eases: Bool { easesScale && bucketing.easesScale }"
        XCTAssertTrue(network.contains(eases))
        XCTAssertFalse(GeekChartBucketing.samples.easesScale || GeekChartBucketing.history.easesScale)
        XCTAssertTrue(GeekChartBucketing.projection.easesScale)
        for direction in ["upload", "download"] {
            XCTAssertTrue(network.contains(
                "maximum: eases ? \(direction)AxisScale.displayedMaximum(fallback: \(direction)Target) : \(direction)Target"),
                direction)
            XCTAssertTrue(network.contains("\(direction)AxisScale.update(targetMaximum: \(direction)Target, at: date)"),
                          direction)
        }
        let disk = try chartSection("struct GeekDiskIOChart: View {")
        XCTAssertTrue(disk.contains("var easesScale = true"))
        XCTAssertTrue(disk.contains(eases))
        for direction in ["read", "write"] {
            XCTAssertTrue(disk.contains(
                "maximum: eases ? \(direction)AxisScale.displayedMaximum(fallback: \(direction)Target) : \(direction)Target"),
                direction)
            XCTAssertTrue(disk.contains("\(direction)AxisScale.update(targetMaximum: \(direction)Target, at: date)"),
                          direction)
        }
        XCTAssertFalse(network.contains("dynamicAxisScale") || disk.contains("dynamicAxisScale"),
                       "No scale is shared between the directions")
    }

    private func chartSection(_ marker: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let charts = try r2ProductionSource(at: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift"))
        return try XCTUnwrap(charts.components(separatedBy: marker).dropFirst().first?
            .components(separatedBy: "\n}\n").first, marker)
    }

    private func networkFrame(reference: Date, upload: Int64?, download: Int64?) -> GeekPreparedNetworkFrame {
        let points = (0..<120).map { index in
            MenuBarTelemetryPoint(
                date: reference.addingTimeInterval(Double(index - 119)), cpuTotal: nil, cpuUser: nil,
                cpuSystem: nil, gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil,
                downBytesPerSecond: download, upBytesPerSecond: upload
            )
        }
        return GeekPreparedNetworkFrame(
            history: GeekNetworkHistorySnapshot(points: points),
            plotRect: CGRect(x: 0, y: 0, width: 240, height: 54),
            duration: 120,
            referenceDate: reference,
            displayScale: 2
        )
    }
}
