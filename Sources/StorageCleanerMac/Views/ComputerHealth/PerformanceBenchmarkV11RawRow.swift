import SwiftUI

struct PerformanceBenchmarkV11RawRow: View {
    @Environment(\.colorScheme) private var scheme
    let id: String
    let metric: MSeriesMeasurement?
    let previous: MSeriesMeasurement?
    let wide: Bool
    var currentResult: BenchmarkV7Result? = nil
    var previousResult: BenchmarkV7Result? = nil
    private var palette: FeatureLightfieldPalette { .resolve(scheme) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if wide {
                HStack(spacing: 10) {
                    Text(MSeriesV11PagePresentation.itemTitle(id)).lineLimit(1).truncationMode(.middle).help(MSeriesV11PagePresentation.itemTitle(id)).frame(maxWidth: .infinity, alignment: .leading)
                    value.frame(width: 130, alignment: .trailing)
                    Text(MSeriesV11PagePresentation.unit(metric?.unit ?? "")).frame(width: 142, alignment: .leading)
                    Text(stability).lineLimit(2).frame(width: 100, alignment: .trailing).help(stability)
                    comparison.frame(width: 114, alignment: .trailing)
                }
            } else {
                Text(MSeriesV11PagePresentation.itemTitle(id)).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle).help(MSeriesV11PagePresentation.itemTitle(id))
                HStack(spacing: 12) {
                    value
                    Text(MSeriesV11PagePresentation.unit(metric?.unit ?? "")).foregroundStyle(palette.fg2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack { Text(stability); Spacer(minLength: 0); comparison }.foregroundStyle(palette.fg2)
            }
        }.font(.system(size: 13)).foregroundStyle(palette.fg).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            .accessibilityElement(children: .combine).lightfieldComponentProbe("performance.raw." + id)
    }
    private var value: some View {
        Text(metric?.statistics.map { MSeriesV11PagePresentation.number($0.median, digits: 2) }
            ?? MSeriesV11PagePresentation.availability(metric?.availability.rawValue ?? "unknown"))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: raw-value
            .lightfieldComponentProbe("performance.raw.value." + id)
    }
    private var stability: String {
        guard let statistics = metric?.statistics else { return MSeriesV11PagePresentation.unread }
        let cv = MSeriesScoringV11.coefficientOfVariation(metric?.samples.map(\.value) ?? [])
        let cvText = cv.map { "CV " + MSeriesV11PagePresentation.number($0 * 100) + "%" } ?? "CV —"
        let rejected = cv.map { $0 > MSeriesScoringV11.maximumCV(id) } ?? true
        return statistics.confidence.rawValue + " · " + cvText + (rejected ? L10n.text(" · 无分", " · unscored") : "")
    }
    private var comparison: some View {
        Group {
            if let metric, let change = MSeriesV11PagePresentation.comparison(metric, previous: previous,
                currentResult: currentResult, previousResult: previousResult) {
                Text((change.percent >= 0 ? "+" : "") + MSeriesV11PagePresentation.number(change.percent) + "% · "
                    + (abs(change.percent) < 0.000001 ? L10n.text("持平", "Same") : change.improved ? L10n.text("改善", "Better") : L10n.text("降低", "Worse")))
                    .foregroundStyle(abs(change.percent) < 0.000001 ? palette.fg2 : change.improved ? FeatureLightfieldStatus.normal.color(palette) : palette.warningColor)
            } else { Text(L10n.text("上次：不可比", "Previous: incomparable")).foregroundStyle(palette.fg2) }
        }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: raw-comparison
    }
}

struct PerformanceBenchmarkV11HistoryList: View {
    @Environment(\.colorScheme) private var scheme
    let history: [BenchmarkV7Result]
    var current: BenchmarkV7Result? = nil
    let onOpen: (BenchmarkV7Result) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("本机历史", "Local history")).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if history.isEmpty { Text(L10n.text("暂无本机历史", "No local history")).font(.system(size: 13)) }
            ForEach(history.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }, id: \.recordID) { record in
                Button { onOpen(record) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            Text(record.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? MSeriesV11PagePresentation.unread)
                            Spacer(minLength: 0)
                            Text(record.mSeriesV11 != nil ? "v11" : record.mSeries != nil ? "v10" : L10n.text("旧协议", "Legacy protocol"))
                        }
                        if let envelope = record.mSeriesV11 {
                            // A differently referenced cache may be opened, but not
                            // silently placed next to a current score for comparison.
                            let displays = MSeriesV11PagePresentation.historyScores(record, current: current)
                            if !displays.isEmpty {
                                LightfieldMetricGroup(metrics: displays.map(\.historyMetric), probeID: "performance.history.scores." + record.session.id.uuidString)
                                ForEach(displays) { display in
                                    if let reason = display.reason {
                                        Text(display.metric.label + " · " + reason)
                                            .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .lightfieldComponentProbe("performance.history.restricted." + display.id + "." + record.session.id.uuidString)
                                    }
                                }
                            } else { Text(L10n.text("分数不可比 · 打开查看", "Scores incomparable · Open to view")) }
                            Text(MSeriesV11PagePresentation.referenceCaption(envelope))
                        } else {
                            Text(L10n.text("保留原协议结果 · 不补填 v11 分数", "Original protocol retained · No fabricated v11 score"))
                        }
                        if let current, MSeriesV11PagePresentation.rawComparable(current, record) {
                            Text(L10n.text("同核心协议 · 按单项证据判断可比性", "Same Core protocol · Comparability depends on each metric's evidence"))
                        }
                    }.font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(FeatureLightfieldRowButtonStyle()).overlay(alignment: .bottom) { FeatureLightfieldHairline() }
                    .accessibilityLabel(L10n.text("打开本机历史", "Open local history") + " · " + (record.completedAt?.formatted() ?? MSeriesV11PagePresentation.unread))
            }
        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
    }
}
