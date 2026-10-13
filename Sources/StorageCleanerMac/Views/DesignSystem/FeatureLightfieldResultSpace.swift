import SwiftUI

/// D77 applies to the requested results only. The other batches keep their
/// established summary/list contract until they opt in separately.
private struct FeatureLightfieldCompactResultsKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var featureLightfieldCompactResults: Bool {
        get { self[FeatureLightfieldCompactResultsKey.self] }
        set { self[FeatureLightfieldCompactResultsKey.self] = newValue }
    }
}

/// Values, not a second view subtree: content publishes its existing summary
/// once and the page renders it once, next to the title in the compact header.
struct FeatureLightfieldResultSummary: Equatable {
    let primary: LightfieldMetric
    var secondary: [LightfieldMetric] = []
    var note: String? = nil
    var probeID = "lightfield.summary"
}
struct FeatureLightfieldResultSummaryKey: PreferenceKey {
    static var defaultValue: FeatureLightfieldResultSummary? { nil }
    static func reduce(value: inout FeatureLightfieldResultSummary?, nextValue: () -> FeatureLightfieldResultSummary?) {
        if let next = nextValue() { value = next }
    }
}

/// A sum rather than last-writer-wins makes simultaneous outgoing/incoming
/// phases observable by the native layout tests and the runtime audit.
struct FeatureLightfieldStateLayersKey: PreferenceKey {
    static let defaultValue: [String: Int] = [:]
    static func reduce(value: inout [String: Int], nextValue: () -> [String: Int]) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}

struct FeatureLightfieldCompactSummary: View {
    @Environment(\.colorScheme) private var scheme
    let summary: FeatureLightfieldResultSummary?
    let fallback: String
    let module: ReviewFilter
    private var palette: FeatureLightfieldPalette { .resolve(scheme) }
    var body: some View {
        Group {
            if let summary {
                GeometryReader { proxy in
                    let count = summary.secondary.count + 1
                    let column = floor(max(1, proxy.size.width - CGFloat(count - 1) * 12) / CGFloat(count))
                    HStack(alignment: .center, spacing: 12) {
                        FeatureLightfieldCompactMetric(value: summary.primary, module: module, note: summary.note,
                            probe: summary.probeID + ".primary.column", valueProbe: summary.probeID + ".primary")
                            .frame(width: column, alignment: .leading)
                        ForEach(summary.secondary) { value in
                            FeatureLightfieldCompactMetric(value: value, module: module,
                                probe: summary.probeID + ".secondary." + value.id,
                                valueProbe: summary.probeID + ".secondary.value." + value.id)
                                .frame(width: column, alignment: .leading)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
                .lightfieldComponentProbe(summary.probeID)
                .lightfieldComponentProbe(summary.probeID + ".container")
            } else {
                Text(fallback).font(.system(size: 13)).foregroundStyle(palette.fg2)
                    .lineLimit(2).truncationMode(.tail).help(fallback)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The same compact numeric columns serve a narrow benchmark's detail row.
/// Full labels/qualifiers are retained in native accessibility and Help.
struct FeatureLightfieldCompactMetric: View {
    @Environment(\.colorScheme) private var scheme
    let value: LightfieldMetric
    let module: ReviewFilter
    var note: String? = nil
    let probe: String
    let valueProbe: String
    private var palette: FeatureLightfieldPalette { .resolve(scheme) }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.label).font(.system(size: 11)).foregroundStyle(palette.fg2).lineLimit(1)
            (Text(value.valuePrefix).font(.system(size: 13)).foregroundColor(palette.fg2)
                + Text(value.value).font(.system(size: 22, weight: .semibold)).foregroundColor(value.status?.color(palette) ?? palette.fg)
                + Text(value.unit.isEmpty ? "" : " " + value.unit).font(.system(size: 13))
                    .foregroundColor(FeatureLightfieldPalette.accent(module)))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: compact-result-value
                .lightfieldComponentProbe(valueProbe)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(value.label + " · " + value.valuePrefix + value.value + (value.unit.isEmpty ? "" : " " + value.unit))
            .accessibilityValue(note ?? value.caption)
            .help([value.label, value.valuePrefix + value.value, value.unit, note ?? value.caption]
                .filter { !$0.isEmpty }.joined(separator: " · "))
            .lightfieldComponentProbe(probe)
    }
}
