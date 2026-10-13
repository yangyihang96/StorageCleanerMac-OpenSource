import Foundation
import XCTest
@testable import StorageCleanerMac

/// D69/SPEC §11: allow each approved text expression and its own lower bound.
/// Adjacent lineLimit belongs to that expression, not another label in its file.
enum MSeriesV11ScaleContract {
    struct Site { let minimum: Double; let receiver: String; var count = 1; var named = true }
    static let allowed: [String: [String: Site]] = [
        "Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldResultSpace.swift": [
            // D77: exact shared numeric expression, never a row/section label.
            "compact-result-value": .init(minimum: 0.5, receiver: "Text(value.valuePrefix).font(.system(size:13)).foregroundColor(palette.fg2)+Text(value.value).font(.system(size:22,weight:.semibold)).foregroundColor(value.status?.color(palette)??palette.fg)+Text(value.unit.isEmpty?\"\":\"\"+value.unit).font(.system(size:13)).foregroundColor(FeatureLightfieldPalette.accent(module))).monospacedDigit().lineLimit(1)"),
        ],
        "Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift": [
            "ring-fitted-value": .init(minimum: 0.1, receiver: "Text(value).font(.system(size:typography.valueSize,weight:.bold)).monospacedDigit().lineLimit(1)"),
            "ring-fitted-unit": .init(minimum: 0.1, receiver: "Text(unit).font(.system(size:typography.unitSize,weight:.medium)).lineLimit(1)"),
            "ring-fitted-label": .init(minimum: 0.1, receiver: "Text(label).font(.system(size:typography.labelSize,weight:labelIsStatus?.semibold:.regular)).foregroundStyle(labelIsStatus?color:palette.fg2).lineLimit(1)"),
            "metric-value": .init(minimum: 0.5, receiver: "Text(metric.value).font(.system(size:showsLabels?22:15,weight:.semibold)).foregroundColor(metric.status?.color(palette)??palette.fg)+Text(metric.unit.isEmpty?\"\":\"\"+metric.unit).font(.system(size:15)).foregroundColor(palette.fg2)).monospacedDigit().lineLimit(1)"),
            "summary-primary": .init(minimum: 0.5, receiver: "Text(valuePrefix).font(.system(size:15)).foregroundColor(palette.fg2)+Text(value).font(.system(size:primaryCaption.isEmpty?52:46,weight:.bold)).foregroundColor(primaryStatus?.color(palette)??palette.fg)+Text(\"\"+unit).font(.system(size:24,weight:.semibold)).foregroundColor(FeatureLightfieldPalette.accent(module))).monospacedDigit().lineLimit(1)"),
            "summary-secondary": .init(minimum: 0.5, receiver: "Text(metric.valuePrefix).font(.system(size:15)).foregroundColor(palette.fg2)+Text(metric.value).font(.system(size:primaryCaption.isEmpty?24:28,weight:.semibold)).foregroundColor(metric.status?.color(palette)??palette.fg)+Text(metric.unit.isEmpty?\"\":\"\"+metric.unit).font(.system(size:15)).foregroundColor(palette.fg2)).monospacedDigit().lineLimit(1)"),
        ],
        "Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldCharts.swift": [
            "chart-axis": .init(minimum: 0.75, receiver: "Text(LightfieldAxisLabel.display(text)).font(.system(size:axis==.percent?13:11,design:.monospaced)).lineLimit(1)"),
            "chart-readout": .init(minimum: 0.8, receiver: "Text(samples[index].time.formatted(date:.omitted,time:.shortened)+\"·\"+detail(at:index)).font(.system(size:13,weight:.semibold,design:.monospaced)).foregroundStyle(palette.fg).lineLimit(1)"),
            "disk-value": .init(minimum: 0.8, receiver: "Text(item.formattedValue).font(.system(size:13)).monospacedDigit().foregroundStyle(palette.fg2).lineLimit(1)"),
            "donut-center": .init(minimum: 0.5, receiver: "Text(centerValue).font(.system(size:15,weight:.semibold)).monospacedDigit().lineLimit(1)"),
            "donut-value": .init(minimum: 0.5, receiver: "Text(item.formattedValue).monospacedDigit().lineLimit(1)"),
            "donut-share": .init(minimum: 0.5, receiver: "Text(share.map{String(format:\"%.1f%%\",$0*100)}??(item.value==0?\"0.0%\":\"—\")).monospacedDigit().foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2).lineLimit(1)"),
        ],
        "Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkV11ResultPage.swift": [
            "result-secondary": .init(minimum: 0.5, receiver: "Text(metric.valuePrefix).font(.system(size:13)).foregroundColor(palette.fg2)+Text(metric.value).font(.system(size:22,weight:.semibold)).foregroundColor(metric.status?.color(palette)??palette.fg)).monospacedDigit().lineLimit(1)"),
            "result-ratio": .init(minimum: 0.5, receiver: "Text(ratio.map{MSeriesV11PagePresentation.number($0,digits:2)+\"×\"}??MSeriesV11PagePresentation.calibration).font(.system(size:17,weight:.semibold,design:.monospaced)).lineLimit(1)"),
        ],
        "Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkV11RawRow.swift": [
            "raw-value": .init(minimum: 0.5, receiver: "Text(metric?.statistics.map{MSeriesV11PagePresentation.number($0.median,digits:2)}??MSeriesV11PagePresentation.availability(metric?.availability.rawValue??\"unknown\")).monospacedDigit().lineLimit(1)"),
            "raw-comparison": .init(minimum: 0.5, receiver: "Group{ifletmetric,letchange=MSeriesV11PagePresentation.comparison(metric,previous:previous,currentResult:currentResult,previousResult:previousResult){Text((change.percent>=0?\"+\":\"\")+MSeriesV11PagePresentation.number(change.percent)+\"%·\"+(abs(change.percent)<0.000001?L10n.text(\"持平\",\"Same\"):change.improved?L10n.text(\"改善\",\"Better\"):L10n.text(\"降低\",\"Worse\"))).foregroundStyle(abs(change.percent)<0.000001?palette.fg2:change.improved?FeatureLightfieldStatus.normal.color(palette):palette.warningColor)}else{Text(L10n.text(\"上次：不可比\",\"Previous:incomparable\")).foregroundStyle(palette.fg2)}}.monospacedDigit().lineLimit(1)"),
        ],
        "Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkV11RunningPage.swift": [
            "running-progress": .init(minimum: 0.5, receiver: "Text(run.displayedFraction.map{\"\\(Int(($0*100).rounded()))%\"}??MSeriesV11PagePresentation.unread).font(.system(size:64,weight:.bold)).monospacedDigit().foregroundStyle(palette.fg).lineLimit(1)"),
            "running-efficiency": .init(minimum: 0.5, receiver: "Text(MSeriesV11PagePresentation.number(currentObservation?.efficiency)).font(.system(size:24,weight:.semibold)).monospacedDigit().lineLimit(1)"),
        ],
        "Sources/StorageCleanerMac/Views/LargeFilesView.swift": [
            "migration-selector-free": .init(minimum: 0.5, receiver: "Text(selectedVolume.map{ByteFormat.storageString($0.availableBytes)}??\"—\").font(.system(size:13)).monospacedDigit().lineLimit(1)", count: 1, named: false),
        ],
        "Sources/StorageCleanerMac/Views/FilesLightfield/FileAnalysisLightfieldView.swift": [
            "analysis-capacity": .init(minimum: 0.5, receiver: "HStack{Text(L10n.text(\"已用\",\"Used\")+ByteFormat.storageString(result.usedVolumeBytes))Spacer(minLength:0)Text(L10n.text(\"可用\",\"Free\")+ByteFormat.storageString(result.volumeAvailableBytes))}.font(.system(size:13)).monospacedDigit().lineLimit(1)", count: 1, named: false),
            "analysis-size": .init(minimum: 0.5, receiver: "Text(ByteFormat.storageString(entry.sizeBytes)).font(.system(size:13)).lineLimit(1)", count: 1, named: false),
            "analysis-share": .init(minimum: 0.5, receiver: "Text(entry.isEstimated?L10n.text(\"估算\",\"Estimated\"):String(format:\"%.1f%%\",share*100)).font(.system(size:13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2).lineLimit(1)", count: 1, named: false),
        ],
        "Sources/StorageCleanerMac/Views/FilesLightfield/FileMigrationLightfieldView.swift": [
            "migration-free": .init(minimum: 0.5, receiver: "Text(destination.map{L10n.text(\"可用\",\"Free\")+ByteFormat.storageString($0.availableBytes)+\"·\"+$0.fileSystem}??\"—\").font(.system(size:13)).monospacedDigit().lineLimit(1)", count: 1, named: false),
            "migration-date": .init(minimum: 0.5, receiver: "Text(entry.modifiedAt.map{$0.formatted(date:.numeric,time:.omitted)}??L10n.text(\"未知\",\"Unknown\")).font(.system(size:13)).monospacedDigit().lineLimit(1)", count: 1, named: false),
            "migration-size": .init(minimum: 0.5, receiver: "Text(ByteFormat.storageString(entry.item.sizeBytes)).font(.system(size:15)).monospacedDigit().lineLimit(1)", count: 1, named: false),
        ],
        "Sources/StorageCleanerMac/Views/FilesLightfield/DuplicateFilesLightfieldView.swift": [
            "duplicate-date": .init(minimum: 0.5, receiver: "Text(modifiedAt.map{$0.formatted(date:.numeric,time:.omitted)}??L10n.text(\"未知\",\"Unknown\")).font(.system(size:13)).monospacedDigit().lineLimit(1)", count: 1, named: false),
            "duplicate-size": .init(minimum: 0.5, receiver: "Text(ByteFormat.storageString(item.sizeBytes)).font(.system(size:13)).monospacedDigit().lineLimit(1)", count: 2, named: false),
        ],
        "Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldFileComponents.swift": [
            "file-metadata": .init(minimum: 0.5, receiver: "Text(metadata).font(.system(size:13)).monospacedDigit().lineLimit(1)", count: 1, named: false),
        ],
    ]
    static func violations(path: String, source: String) -> [String] {
        let sites = allowed[path] ?? [:]
        let lines = source.components(separatedBy: .newlines)
        var failures: [String] = [], seen: [String: Int] = [:], prefix = ""
        let pattern = try! NSRegularExpression(pattern: #"\.minimumScaleFactor\(([0-9.]+)\).*// lightfield-scale-ok(?:: ([a-z-]+))?$"#)
        let calls = try! NSRegularExpression(pattern: #"\.minimumScaleFactor\s*\("#)
        for line in lines {
            let invocations = calls.matches(in: line, range: NSRange(line.startIndex..., in: line))
            let callCount = invocations.count
            if callCount > 1 { failures.append("multiple scale calls on one line") }
            if let invocation = invocations.first, let range = Range(invocation.range, in: line) {
                let ns = line as NSString
                guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                    failures.append("unmarked or nonliteral scale"); prefix += line; continue
                }
                let value = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let receiver = (prefix + line[..<range.lowerBound]).filter { !$0.isWhitespace }
                let named = match.range(at: 2).location != NSNotFound
                let id: String
                if named { id = ns.substring(with: match.range(at: 2)) }
                else {
                    let matching = sites.filter { !$0.value.named && receiver.hasSuffix($0.value.receiver) }
                    guard matching.count == 1, let key = matching.keys.first else {
                        failures.append("unapproved legacy expression"); prefix += line + "\n"; continue
                    }
                    id = key
                }
                seen[id, default: 0] += 1
                if let site = sites[id], site.named == named {
                    if value < site.minimum || value > 1 { failures.append(id + ": below approved minimum") }
                    if !receiver.hasSuffix(site.receiver) { failures.append(id + ": wrong expression or missing adjacent single-line modifier") }
                } else { failures.append("unapproved site: " + id) }
            }
            prefix += line + "\n"
        }
        for (id, site) in sites where seen[id] != site.count { failures.append(id + ": wrong exact occurrence count") }
        return failures
    }
}

final class MSeriesV11ScaleContractTests: XCTestCase {
    func testApprovedSitesAreExactAndContainAdjacentSingleLineAndMinimum() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in MSeriesV11ScaleContract.allowed.keys {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(MSeriesV11ScaleContract.violations(path: path, source: source).isEmpty, path)
            XCTAssertFalse(MSeriesV11ScaleContract.violations(path: "Other/" + path, source: source).isEmpty, "allowed names cannot be transplanted to another file")
        }
    }
    func testSameLineOverlayScaleCounterexampleIsRejected() throws {
        let path = "Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkV11RunningPage.swift"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        let approved = ".lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: running-progress"
        let counterexample = ".lineLimit(1).minimumScaleFactor(0.5).overlay { Text(\"ordinary caption\").lineLimit(1).minimumScaleFactor(0.01) } // lightfield-scale-ok: running-progress"
        XCTAssertEqual(source.components(separatedBy: approved).count - 1, 1)
        XCTAssertTrue(MSeriesV11ScaleContract.violations(path: path, source: source).isEmpty)
        let changed = source.replacingOccurrences(of: approved, with: counterexample)
        XCTAssertTrue(MSeriesV11ScaleContract.violations(path: path, source: changed).contains("multiple scale calls on one line"))
        // A second call is forbidden even if its own ratio would be acceptable;
        // a site marker belongs to exactly one expression.
        XCTAssertFalse(MSeriesV11ScaleContract.violations(path: path,
            source: changed.replacingOccurrences(of: "minimumScaleFactor(0.01)", with: "minimumScaleFactor(0.5)")).isEmpty)
    }
    func testMinimumSingleLineReceiverDuplicateAndExtraSiteCounterexamples() throws {
        let path = "Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkV11RunningPage.swift"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        for negative in [
            source.replacingOccurrences(of: ".minimumScaleFactor(0.5)", with: ".minimumScaleFactor(0.01)"),
            source.replacingOccurrences(of: ".lineLimit(1).minimumScaleFactor", with: ".lineLimit(3).minimumScaleFactor"),
            source.replacingOccurrences(of: "Text(run.displayedFraction.map", with: "Text(run.position.map"),
            source + "\nText(\"unapproved\").lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: running-progress",
            source + "\nText(\"unapproved\").lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: extra"
        ] { XCTAssertFalse(MSeriesV11ScaleContract.violations(path: path, source: negative).isEmpty) }
    }
}
