#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D146: iStat Menus 7.30's peak rows (`-[BBRNetworkMenuBandwidthView
/// drawRect:]`, `-[BBRDisksMenuActivityView drawRect:]` and their
/// `format:label:alignment:`). A peak is the maximum of the newest samples
/// the graph draws, the bandwidth's at least 1024 B/s (it is the graph's
/// scale), the disk activity's without a floor. A row is "Label: value",
/// '%1$@: %2$@' (zh-CN '%1$@：%2$@') with the label replacing "%1$@:", or
/// "%1$@" where that is missing; the upload or read peak at x 8, the
/// download or write peak ending 8 from the right. Fixtures only; renders
/// offscreen. No window, sampling or user data.
@MainActor
final class MiniWindowIStatPeakRowTests: XCTestCase {
    private static let scale: CGFloat = 2
    /// iStat's 375 pt card less 8 pt each side: 120 bars of 3 pt.
    private static let plot = CGRect(x: 0, y: 0, width: 359, height: 56)
    private static let reference = Date(timeIntervalSince1970: 1_800_000_000)
    /// Older than the drawn samples and far higher, as a window's peak.
    private static let olderRate: Int64 = 9_000_000_000

    // MARK: - The peaks

    func testTheBandwidthPeaksAreTheDrawnSamplesScaleAtLeastOneKilobyte() {
        let slots = GeekChartWindow.barSlotCount(in: Self.plot, displayScale: Self.scale)
        XCTAssertEqual(slots, 120)
        let frame = Self.networkFrame(
            uploads: Self.samples(drawn: slots, peak: 5_000),
            downloads: Self.samples(drawn: slots, peak: 300))
        XCTAssertEqual(frame.uploadMaximum, 5_000, "the drawn samples' maximum, not the window's")
        XCTAssertEqual(frame.downloadMaximum, 1_024, "at least 1 KB/s")
    }

    func testTheDiskPeaksAreTheDrawnSamplesMaximumWithoutAFloor() {
        let slots = GeekChartWindow.barSlotCount(in: Self.plot, displayScale: Self.scale)
        let frame = Self.diskFrame(reads: Self.samples(drawn: slots, peak: 300),
                                   writes: Self.samples(drawn: slots, peak: 0))
        XCTAssertEqual(frame.readPeak, 300, "the drawn samples' maximum, without a floor")
        XCTAssertEqual(frame.readMaximum, 1_024, "the scale keeps its floor")
        XCTAssertEqual(frame.writePeak, 0, "a recorded zero is a peak of zero")
        let empty = Self.diskFrame(reads: [], writes: [])
        XCTAssertNil(empty.readPeak, "no bar, no reading")
        XCTAssertNil(empty.writePeak)
    }

    // MARK: - The rows

    func testTheRowsFormatTheGraphsPeaksAndShowUnknownWithoutThem() {
        let network = GeekNetworkPeakRow(peaks: GeekMirroredChartPeaks(upward: 1_500_000_000, downward: 1_024))
        XCTAssertEqual(network.uploadPeak, IStatNumberFormat.bandwidth(1_500_000_000.0, style: .menu))
        XCTAssertEqual(network.downloadPeak, IStatNumberFormat.bandwidth(1_024.0, style: .menu))
        let disk = GeekDiskPeakRow(peaks: GeekMirroredChartPeaks(upward: 1_500_000_000, downward: nil))
        XCTAssertEqual(disk.readPeak, IStatNumberFormat.diskActivity(1_500_000_000.0, style: .menu))
        XCTAssertEqual(disk.writePeak, "--", "a half without bars has no reading")
        let unknown = GeekNetworkPeakRow(peaks: nil)
        XCTAssertEqual([unknown.uploadPeak, unknown.downloadPeak], ["--", "--"])
        let unknownDisk = GeekDiskPeakRow(peaks: nil)
        XCTAssertEqual([unknownDisk.readPeak, unknownDisk.writePeak], ["--", "--"])
    }

    /// '%1$@: %2$@' loses its colon with the "%1$@:" it replaces; zh-CN's
    /// '%1$@：%2$@' keeps the full-width one, in the value's attributes.
    func testTheRowKeepsWhatIStatsFormatLeavesBetweenLabelAndValue() throws {
        for (language, separator) in [(AppLanguage.zhHans, "："), (.english, " ")] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual(GeekIStatPeakValue.separator, separator, "\(language)")
        }
        let disk = try Self.source("GeekDiskView.swift")
        let value = try MiniWindowLogicFixtures.section(disk, from: "struct GeekIStatPeakValue: View {", to: "\n}\n")
        XCTAssertTrue(value.contains("Text(title)\n                .geekIStatLabelText()"))
        XCTAssertTrue(value.contains("Text(Self.separator)\n                .geekIStatValueText()"))
        XCTAssertTrue(value.contains("unitFontSize: GeekSecondaryTransferLayout.rowUnitFontSize"))
        XCTAssertTrue(value.contains(".modifier(GeekIStatTextColor(role: .value))"))
        XCTAssertEqual(GeekSecondaryTransferLayout.rowUnitFontSize, 10)
        XCTAssertEqual(GeekSecondaryTransferLayout.processNumberFontSize, 12)
    }

    /// iStat draws a peak with `drawAtPoint:`, never shrunk or cut: offered
    /// less than its width, the value keeps it (in the D146 mutation run, P22
    /// dropped `.fixedSize()`, the value took the offer, and no test noticed).
    func testAPeakKeepsItsWidthWhereTheRowIsTooNarrow() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let host = NSHostingController(rootView: GeekIStatPeakValue(
                title: L10n.text("读", "Read"), value: "1023.9 TiB/s", accessibilityLabel: ""))
            let natural = host.sizeThatFits(in: CGSize(width: 10_000, height: 100)).width
            let offered = host.sizeThatFits(in: CGSize(width: natural / 3, height: 100)).width
            XCTAssertGreaterThan(natural, 60, "\(language)")
            XCTAssertEqual(offered, natural, accuracy: 0.5, "\(language)")
        }
    }

    /// 'Network.Upload', 'Network.Download', 'Disks.Read', 'Disks.Write'.
    func testTheRowsUseIStatsLabels() throws {
        let network = try MiniWindowLogicFixtures.section(try Self.source("GeekNetworkView.swift"),
            from: "struct GeekNetworkPeakRow: View {", to: "\n}\n")
        XCTAssertTrue(network.contains("GeekIStatPeakValue(title: L10n.text(\"上传\", \"Upload\"), value: uploadPeak,"))
        XCTAssertTrue(network.contains("GeekIStatPeakValue(title: L10n.text(\"下载\", \"Download\"), value: downloadPeak,"))
        let disk = try MiniWindowLogicFixtures.section(try Self.source("GeekDiskView.swift"),
            from: "struct GeekDiskPeakRow: View {", to: "\n}\n")
        XCTAssertTrue(disk.contains("GeekIStatPeakValue(title: L10n.text(\"读\", \"Read\"), value: readPeak,"))
        XCTAssertTrue(disk.contains("GeekIStatPeakValue(title: L10n.text(\"写\", \"Write\"), value: writePeak,"))
    }

    // MARK: - The cards

    /// The disk activity card's row shows the peaks of the graph in its
    /// graph layer: the newest samples' only, the read's above 1 GB/s and
    /// the write's under 1 KB/s as they are.
    func testTheDiskCardsRowShowsItsGraphsPeaks() throws {
        let width: CGFloat = 296
        let graph = CGRect(x: 0, y: 0,
                           width: width - GeekIStatCardGeometry.inset - GeekIStatCardGeometry.processorGraphTrailingInset,
                           height: GeekDiskIOCardLayout.chartHeight)
        let slots = GeekChartWindow.barSlotCount(in: graph, displayScale: Self.scale)
        let points = Self.diskPoints(reads: Self.samples(drawn: slots, peak: 1_500_000_000),
                                     writes: Self.samples(drawn: slots, peak: 300))
        let band = GeekDiskIOCardLayout.peakTop..<(GeekDiskIOCardLayout.peakTop + GeekDiskIOCardLayout.peakHeight)
        for dark in [false, true] {
            let live = try Self.render(GeekDiskIOCard { EmptyView() } write: { EmptyView() } chart: {
                GeekDiskIOChart(points: points, accessibilityLabel: "", duration: 3_600, showsLegend: false,
                                showsTimelineLabels: false, horizontalInset: 0, verticalInset: 0,
                                mirroredHalfInset: 0, bucketing: .samples)
            } peak: { GeekDiskPeakRow(peaks: $0) }, width: width, dark: dark)
            let expected = try Self.render(Self.diskCard(
                read: IStatNumberFormat.diskActivity(1_500_000_000.0),
                write: IStatNumberFormat.diskActivity(300.0)), width: width, dark: dark)
            let window = try Self.render(Self.diskCard(
                read: IStatNumberFormat.diskActivity(Double(Self.olderRate)),
                write: IStatNumberFormat.diskActivity(Double(Self.olderRate))), width: width, dark: dark)
            let liveMask = Self.mask(live, dark: dark, rows: band)
            XCTAssertTrue(liveMask.contains(true), "the row is drawn")
            XCTAssertTrue(liveMask == Self.mask(expected, dark: dark, rows: band), "dark \(dark)")
            XCTAssertFalse(liveMask == Self.mask(window, dark: dark, rows: band), "not the window's peaks")
        }
    }

    /// The bandwidth graph hands the row its scales: the newest samples'
    /// maximum and at least 1 KB/s. (`geekNetworkTrendCard` reads them on
    /// its graph layer, as the disk activity card does.)
    func testTheBandwidthGraphHandsTheRowItsScales() throws {
        let slots = GeekChartWindow.barSlotCount(in: Self.plot, displayScale: Self.scale)
        let points = Self.networkPoints(uploads: Self.samples(drawn: slots, peak: 1_500_000_000),
                                        downloads: Self.samples(drawn: slots, peak: 300))
        for dark in [false, true] {
            let live = try Self.render(GeekPrecisionNetworkChart(points: points, accessibilityLabel: "",
                    duration: 3_600, showsLegend: false, showsTimelineLabels: false, horizontalInset: 0,
                    verticalInset: 0, mirroredHalfInset: 0, bucketing: .samples)
                .frame(height: Self.plot.height)
                .opacity(0)
                .overlayPreferenceValue(GeekMirroredChartPeaksKey.self) { GeekNetworkPeakRow(peaks: $0) },
                width: Self.plot.width, dark: dark)
            let expected = try Self.render(Self.networkRow(
                upload: IStatNumberFormat.bandwidth(1_500_000_000.0),
                download: IStatNumberFormat.bandwidth(1_024.0)), width: Self.plot.width, dark: dark)
            let unfloored = try Self.render(Self.networkRow(
                upload: IStatNumberFormat.bandwidth(1_500_000_000.0),
                download: IStatNumberFormat.bandwidth(300.0)), width: Self.plot.width, dark: dark)
            let liveMask = Self.mask(live, dark: dark)
            XCTAssertTrue(liveMask.contains(true), "the row is drawn")
            XCTAssertTrue(liveMask == Self.mask(expected, dark: dark), "dark \(dark)")
            XCTAssertFalse(liveMask == Self.mask(unfloored, dark: dark), "the download's 1 KB/s floor")
        }
        let card = try MiniWindowLogicFixtures.section(try Self.source("GeekNetworkView.swift"),
            from: "private var geekNetworkTrendCard: some View {", to: "\n    }\n")
        XCTAssertTrue(card.contains(
            "trailing: GeekIStatCardGeometry.processorGraphTrailingInset)\n            // iStat's peak row"))
        XCTAssertTrue(card.contains(".overlayPreferenceValue(GeekMirroredChartPeaksKey.self) { peaks in"))
        XCTAssertTrue(card.contains("GeekNetworkPeakRow(peaks: peaks)\n                    .geekIStatLayer(top: GeekNetworkBandwidthLayout.peakTop"))
    }

    /// A half the graph draws no bars of has no peak, "--" as before the
    /// graph has a frame (iStat's zero-filled history would show 0 or
    /// 1 KB/s): the bandwidth without upload or without download readings,
    /// and a disk graph of one direction (the hover pages'). The other half
    /// keeps its peak, the bandwidth's at least 1 KB/s, the disk's as it is.
    func testAHalfWithoutBarsHasNoPeak() throws {
        let slots = GeekChartWindow.barSlotCount(in: Self.plot, displayScale: Self.scale)
        let rates = Self.samples(drawn: slots, peak: 300)
        let drawn: [Int64?] = rates
        let none = [Int64?](repeating: nil, count: rates.count)
        let floor = IStatNumberFormat.bandwidth(1_024.0)
        let small = IStatNumberFormat.diskActivity(300.0)
        XCTAssertNotEqual(small, IStatNumberFormat.diskActivity(1_024.0), "the fixture tells a floor apart")
        for dark in [false, true] {
            for (uploads, downloads, upload, download) in [(none, drawn, "--", floor), (drawn, none, floor, "--")] {
                let live = try Self.render(Self.peakRow(of: Self.networkChart(
                    Self.networkPoints(uploads: uploads, downloads: downloads))) { GeekNetworkPeakRow(peaks: $0) },
                    width: Self.plot.width, dark: dark)
                let expected = try Self.render(Self.networkRow(upload: upload, download: download),
                                               width: Self.plot.width, dark: dark)
                let liveMask = Self.mask(live, dark: dark)
                XCTAssertTrue(liveMask.contains(true), "the row is drawn")
                XCTAssertTrue(liveMask == Self.mask(expected, dark: dark), "\(upload) \(download), dark \(dark)")
            }
            for mode in [GeekDiskIOChartMode.read, .write] {
                let live = try Self.render(Self.peakRow(of: Self.diskChart(
                    Self.diskPoints(reads: rates, writes: rates), mode: mode)) { GeekDiskPeakRow(peaks: $0) },
                    width: Self.plot.width, dark: dark)
                let expected = try Self.render(Self.diskRow(read: mode == .read ? small : "--",
                                                            write: mode == .write ? small : "--"),
                                               width: Self.plot.width, dark: dark)
                XCTAssertTrue(Self.mask(live, dark: dark) == Self.mask(expected, dark: dark), "\(mode), dark \(dark)")
            }
        }
    }

    /// iStat draws the upload or read peak at x 8 and ends the download or
    /// write peak 8 from the right (`drawAtPoint:` at 8 and at W − 8 − its
    /// width): the leading peak's text runs from the leading inset at its own
    /// width, the trailing peak's ends at the trailing inset, nothing between.
    func testThePeaksSitAtTheCardsInsets() throws {
        let width: CGFloat = 296
        let band = GeekDiskIOCardLayout.peakTop..<(GeekDiskIOCardLayout.peakTop + GeekDiskIOCardLayout.peakHeight)
        let inset = Int(GeekIStatCardGeometry.inset * Self.scale)
        let right = Int(width * Self.scale) - inset
        let long = "1023.9 TiB/s", short = "--"
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for dark in [false, true] {
                let ink = Self.ink(try Self.render(Self.diskCard(read: long, write: short), width: width, dark: dark),
                                   dark: dark, rows: band)
                let leading = try Self.render(GeekIStatPeakValue(title: L10n.text("读", "Read"), value: long,
                    accessibilityLabel: ""), width: nil, dark: dark).pixelsWide
                let trailing = try Self.render(GeekIStatPeakValue(title: L10n.text("写", "Write"), value: short,
                    accessibilityLabel: ""), width: nil, dark: dark).pixelsWide
                let context = "\(language), dark \(dark)"
                let first = try XCTUnwrap(ink.first, "the row is drawn, \(context)")
                let last = try XCTUnwrap(ink.last)
                XCTAssertEqual(Double(first), Double(inset), accuracy: 4, "x 8, \(context)")
                XCTAssertEqual(Double(last), Double(right), accuracy: 4, "W − 8, \(context)")
                let leadingOnly = (inset + trailing + 4)..<(inset + leading - 4)
                let between = (inset + leading + 4)..<(right - trailing - 4)
                guard !leadingOnly.isEmpty, !between.isEmpty else {
                    XCTFail("the fixture's peaks are \(leading) and \(trailing) px wide, \(context)")
                    continue
                }
                XCTAssertFalse(ink.intersection(IndexSet(integersIn: leadingOnly)).isEmpty,
                               "the leading peak is the read's, \(context)")
                XCTAssertTrue(ink.intersection(IndexSet(integersIn: between)).isEmpty, "nothing between, \(context)")
            }
        }
    }

    /// `geekDiskTrend` puts its graph in a hover target; the peaks reach the
    /// row through it as from the bare graph.
    func testTheDiskTrendsGraphHandsItsPeaksThroughItsHoverTarget() throws {
        let width: CGFloat = 296
        let graph = CGRect(x: 0, y: 0,
                           width: width - GeekIStatCardGeometry.inset - GeekIStatCardGeometry.processorGraphTrailingInset,
                           height: GeekDiskIOCardLayout.chartHeight)
        let slots = GeekChartWindow.barSlotCount(in: graph, displayScale: Self.scale)
        let points = Self.diskPoints(reads: Self.samples(drawn: slots, peak: 1_500_000_000),
                                     writes: Self.samples(drawn: slots, peak: 300))
        let band = GeekDiskIOCardLayout.peakTop..<(GeekDiskIOCardLayout.peakTop + GeekDiskIOCardLayout.peakHeight)
        for dark in [false, true] {
            let live = try Self.render(GeekDiskIOCard { EmptyView() } write: { EmptyView() } chart: {
                GeekHoverDetailTarget(accessibilityLabel: "", chartRangeMetric: .disk,
                                      popoverSize: GeekHoverDetailMetrics.diskIOSize, usesCardActiveBorder: true) {
                    Self.diskChart(points)
                } detail: {
                    EmptyView()
                }
            } peak: { GeekDiskPeakRow(peaks: $0) }, width: width, dark: dark)
            let expected = try Self.render(Self.diskCard(
                read: IStatNumberFormat.diskActivity(1_500_000_000.0),
                write: IStatNumberFormat.diskActivity(300.0)), width: width, dark: dark)
            let liveMask = Self.mask(live, dark: dark, rows: band)
            XCTAssertTrue(liveMask.contains(true), "the row is drawn")
            XCTAssertTrue(liveMask == Self.mask(expected, dark: dark, rows: band), "dark \(dark)")
        }
        let trend = try MiniWindowLogicFixtures.section(try Self.source("GeekDiskView.swift"),
            from: "private var geekDiskTrend: some View {", to: "\n    }\n")
        XCTAssertTrue(trend.contains("GeekHoverDetailTarget("))
        XCTAssertTrue(trend.contains("} peak: { peaks in\n            GeekDiskPeakRow(peaks: peaks)\n        }"))
    }

    /// VoiceOver reads each peak as one element by its full name, with the
    /// value; the label on screen is iStat's short one.
    func testVoiceOverReadsEachPeakByItsFullName() throws {
        let disk = try Self.source("GeekDiskView.swift")
        let value = try MiniWindowLogicFixtures.section(disk, from: "struct GeekIStatPeakValue: View {", to: "\n}\n")
        XCTAssertTrue(value.contains(
            ".accessibilityElement(children: .ignore)\n        .accessibilityLabel(accessibilityLabel)\n        .accessibilityValue(value)"))
        let diskRow = try MiniWindowLogicFixtures.section(disk, from: "struct GeekDiskPeakRow: View {", to: "\n}\n")
        XCTAssertTrue(diskRow.contains("accessibilityLabel: L10n.text(\"读取峰值\", \"Read peak\")"))
        XCTAssertTrue(diskRow.contains("accessibilityLabel: L10n.text(\"写入峰值\", \"Write peak\")"))
        let networkRow = try MiniWindowLogicFixtures.section(try Self.source("GeekNetworkView.swift"),
            from: "struct GeekNetworkPeakRow: View {", to: "\n}\n")
        XCTAssertTrue(networkRow.contains("accessibilityLabel: L10n.text(\"上传峰值\", \"Upload peak\")"))
        XCTAssertTrue(networkRow.contains("accessibilityLabel: L10n.text(\"下载峰值\", \"Download peak\")"))
    }

    // MARK: - Fixtures

    /// Five older samples first, then `drawn` at half `peak` with `peak` once.
    private static func samples(drawn: Int, peak: Int64) -> [Int64] {
        guard drawn > 0 else { return [] }
        return Array(repeating: olderRate, count: 5) + (0..<drawn).map { $0 == drawn / 2 ? peak : peak / 2 }
    }

    /// One sample a second, the newest at `reference`.
    private static func date(_ index: Int, of count: Int) -> Date {
        reference.addingTimeInterval(Double(index - count + 1))
    }

    private static func networkPoints(uploads: [Int64?], downloads: [Int64?]) -> [MenuBarTelemetryPoint] {
        zip(uploads, downloads).enumerated().map { index, rates in
            MenuBarTelemetryPoint(date: date(index, of: uploads.count), cpuTotal: nil, cpuUser: nil,
                                  cpuSystem: nil, gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil,
                                  downBytesPerSecond: rates.1, upBytesPerSecond: rates.0)
        }
    }

    private static func diskPoints(reads: [Int64], writes: [Int64]) -> [NativeDiskIOPoint] {
        zip(reads, writes).enumerated().map { index, rates in
            NativeDiskIOPoint(date: date(index, of: reads.count), readBytesPerSecond: rates.0,
                              writeBytesPerSecond: rates.1, readOperationsPerSecond: 0, writeOperationsPerSecond: 0)
        }
    }

    private static func networkFrame(uploads: [Int64], downloads: [Int64]) -> GeekPreparedNetworkFrame {
        GeekPreparedNetworkFrame(history: GeekNetworkHistorySnapshot(points: networkPoints(uploads: uploads,
            downloads: downloads)), plotRect: plot, duration: 3_600, referenceDate: reference,
            displayScale: scale, bucketing: .samples)
    }

    private static func diskFrame(reads: [Int64], writes: [Int64]) -> GeekPreparedDiskFrame {
        GeekPreparedDiskFrame(points: diskPoints(reads: reads, writes: writes), plot: plot, duration: 3_600,
                              reference: reference, scale: scale, bucketing: .samples)
    }

    private static func diskCard(read: String, write: String) -> some View {
        GeekDiskIOCard { EmptyView() } write: { EmptyView() } chart: { Color.clear } peak: { _ in
            GeekDiskPeakRow(readPeak: read, writePeak: write)
        }
    }

    private static func networkRow(upload: String, download: String) -> some View {
        Color.clear.frame(height: plot.height).overlay {
            GeekNetworkPeakRow(uploadPeak: upload, downloadPeak: download)
        }
    }

    private static func diskRow(read: String, write: String) -> some View {
        Color.clear.frame(height: plot.height).overlay {
            GeekDiskPeakRow(readPeak: read, writePeak: write)
        }
    }

    /// The row a graph hands its peaks to, over the graph drawn invisible.
    private static func peakRow<Chart: View, Row: View>(
        of chart: Chart, @ViewBuilder row: @escaping (GeekMirroredChartPeaks?) -> Row
    ) -> some View {
        chart
            .frame(height: plot.height)
            .opacity(0)
            .overlayPreferenceValue(GeekMirroredChartPeaksKey.self) { row($0) }
    }

    private static func diskChart(_ points: [NativeDiskIOPoint], mode: GeekDiskIOChartMode = .combined) -> GeekDiskIOChart {
        GeekDiskIOChart(points: points, accessibilityLabel: "", mode: mode, duration: 3_600, showsLegend: false,
                        showsTimelineLabels: false, horizontalInset: 0, verticalInset: 0,
                        mirroredHalfInset: 0, bucketing: .samples)
    }

    private static func networkChart(_ points: [MenuBarTelemetryPoint]) -> GeekPrecisionNetworkChart {
        GeekPrecisionNetworkChart(points: points, accessibilityLabel: "", duration: 3_600, showsLegend: false,
                                  showsTimelineLabels: false, horizontalInset: 0, verticalInset: 0,
                                  mirroredHalfInset: 0, bucketing: .samples)
    }

    /// The columns (pixels) with ink, any pixel off the background, of the
    /// rows in `rows` (points), 4 pt in from each side (the card's edge).
    private static func ink(_ bitmap: NSBitmapImageRep, dark: Bool, rows: Range<CGFloat>) -> IndexSet {
        let first = max(0, Int((rows.lowerBound * scale).rounded()))
        let last = min(bitmap.pixelsHigh, Int((rows.upperBound * scale).rounded()))
        let edge = Int(4 * scale)
        var columns = IndexSet()
        for x in edge..<(bitmap.pixelsWide - edge) {
            for y in first..<last {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let level = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                if dark ? level > 0.3 : level < 0.7 {
                    columns.insert(x)
                    break
                }
            }
        }
        return columns
    }

    private static func source(_ name: String) throws -> String {
        try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/\(name)")
    }

    /// At `width`, or the view's own width without one.
    private static func render<V: View>(_ view: V, width: CGFloat?, dark: Bool) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view
            .frame(width: width)
            .environment(\.menuBarChartsPreparedInline, true)
            .environment(\.miniWindowPreviewDate, reference)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.miniWindowVisualMode, .black)
            .environment(\.displayScale, scale)
            .background(dark ? Color.black : Color.white))
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// Pixels of neutral primary text (the values), of the rows in `rows`
    /// (points) when given.
    private static func mask(_ bitmap: NSBitmapImageRep, dark: Bool, rows: Range<CGFloat>? = nil) -> [Bool] {
        let first = rows.map { Int(($0.lowerBound * scale).rounded()) } ?? 0
        let last = rows.map { Int(($0.upperBound * scale).rounded()) } ?? bitmap.pixelsHigh
        return (max(0, first)..<min(bitmap.pixelsHigh, last)).flatMap { y in (0..<bitmap.pixelsWide).map { x in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  color.alphaComponent > 0.8 else { return false }
            let components = [color.redComponent, color.greenComponent, color.blueComponent]
            guard let minimum = components.min(), let maximum = components.max(),
                  maximum - minimum < 0.05 else { return false }
            return dark ? minimum > 0.7 : maximum < 0.4
        } }
    }
}
#endif
