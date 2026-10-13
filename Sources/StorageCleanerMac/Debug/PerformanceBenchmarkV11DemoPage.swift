#if DEBUG
import SwiftUI

/// Value-only screenshot route through the production v11 pages. No store,
/// benchmark, helper request, history write or reference activation is started.
struct PerformanceBenchmarkV11DemoPage: View {
    let phase: FeaturePresentationDemo.Phase
    var variant = "standard"
    var initialSection = 0
    var stage = "core"
    @State private var selection = MSeriesV11Selection()
    private let result: BenchmarkV7Result
    init(phase: FeaturePresentationDemo.Phase, variant: String = "standard", initialSection: Int = 0, stage: String = "core") {
        self.phase = phase; self.variant = variant; self.initialSection = initialSection; self.stage = stage
        result = MSeriesV11PageFixture.result(variant: variant)
    }
    static func argument(_ key: String, arguments: [String] = ProcessInfo.processInfo.arguments, fallback: String) -> String {
        let prefix = "--debug-benchmark-v11-" + key + "="
        return arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? fallback
    }
    @ViewBuilder var body: some View {
        switch phase {
        case .landing:
            PerformanceBenchmarkLandingView(canStart: true, onStart: {}, onShowSaved: {},
                identity: MSeriesV11PageFixture.identity, catalog: MSeriesV11PageFixture.catalog,
                preflight: result.preflight, helperAvailable: variant != "nohelper", selection: $selection)
        case .running:
            let state = runState
            PerformanceBenchmarkV11RunningPage(run: .init(state: state,
                weightedFraction: stage == "core" ? 0.42 : 0.99, elapsedSeconds: stage == "core" ? 68 : 452,
                knownCoreCount: stage == "core" ? 12 : 18),
                telemetry: variant == "nohelper" ? [] : MSeriesV11PageFixture.telemetry,
                systemTelemetry: Self.systemTelemetry, onCancel: {})
        case .result:
            if let core = result.mSeries, result.mSeriesV11 == nil {
                ScrollView { MSeriesRawResultView(result: core).padding(24) }
            } else if result.mSeriesV11 != nil {
                PerformanceBenchmarkV11ResultPage(result: result, history: [result], catalog: MSeriesV11PageFixture.catalog,
                    canStart: true, onStart: {}, onOpenHistory: { _ in }, initialSection: initialSection)
            } else {
                // Legacy v9 has its frozen own score schema. A read-only
                // degraded presentation deliberately retains the old unit.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("旧协议 v9 · 原始记录", "Legacy v9 · Original record")).font(.title2)
                        Text(result.session.plan.workloadVersion)
                        ForEach(result.metrics, id: \.manifest.id) { metric in
                            HStack {
                                Text(metric.manifest.category.rawValue); Spacer(minLength: 8)
                                Text(MSeriesV11PagePresentation.number(metric.statistics.median) + " " + metric.manifest.unit).monospacedDigit()
                            }
                        }
                    }.padding(24)
                }
            }
        }
    }
    private var runState: BenchmarkV7State {
        let id = MSeriesV11PageFixture.runState.sessionID ?? result.session.id
        switch stage {
        case "saving": return .phase(.persisting, sessionID: id)
        case "stopping": return .phase(.cancelling, sessionID: id)
        case "extension": return .phase(.running, sessionID: id, workloadID: "sustained.cpu.allCores")
        default: return MSeriesV11PageFixture.runState
        }
    }
    static var systemTelemetry: [MenuBarTelemetryPoint] {
        let now = Date.now
        return (0..<30).map { index in
            .init(date: now.addingTimeInterval(Double(index - 29) * 2), cpuTotal: 0.7, cpuUser: 0.6,
                cpuSystem: 0.1, gpu: 0.3, memory: 0.5, chipTemperature: 54 + Double(index) / 2,
                fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil)
        }
    }
}
#endif
