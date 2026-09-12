import SwiftUI

struct MacBenchmarkResultOverview: View {
    let result: MacBenchmarkResult
    let explicitRawOnlyReason: MacBenchmarkRawOnlyPresentationReason?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    L10n.text("最近结果", "Latest Result"),
                    systemImage: AppSymbols.Benchmark.history
                )
                    .font(AppDesignTokens.Typography.sectionTitle)
                Spacer()
                if let completedAt = result.rawResult?.completedAt {
                    Text(completedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            if let displayScore = MacBenchmarkPresentation.displayScore(for: result) {
                comparisonSummary(score: displayScore.overallScore)
                if result.overallScore == nil,
                   let reason = MacBenchmarkPresentation.rawOnlyReason(
                    for: result,
                    explicitReason: explicitRawOnlyReason
                   ) {
                    nonLeaderboardBanner(reason)
                }
            } else if let reason = MacBenchmarkPresentation.rawOnlyReason(
                for: result,
                explicitReason: explicitRawOnlyReason
            ) {
                rawOnlyBanner(reason)
            }

            if let raw = result.rawResult {
                environmentGrid(raw)
            }

            Divider()
        }
        .padding(.horizontal, AppDesignTokens.Spacing.compact)
        .padding(.vertical, AppDesignTokens.Spacing.small)
    }

    private func comparisonSummary(score: Double) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            Label(
                result.comparisonKey == nil
                    ? MacBenchmarkPresentation.activeReferenceSummary
                    : MacBenchmarkPresentation.referenceSummary(for: result),
                systemImage: "equal.circle.fill"
            )
            .font(AppDesignTokens.Typography.cardTitle)
            .fixedSize(horizontal: false, vertical: true)

            MacBenchmarkScoreComparisonBars(
                score: score,
                reference: MacBenchmarkScoring.referenceTotalScore
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func rawOnlyBanner(_ reason: MacBenchmarkRawOnlyPresentationReason) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.title2)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(MacBenchmarkPresentation.rawOnlyTitle(reason))
                    .font(AppDesignTokens.Typography.cardTitle)
                Text(MacBenchmarkPresentation.rawOnlyDetail(reason))
                    .font(AppDesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, AppDesignTokens.Spacing.compact)
        .accessibilityElement(children: .combine)
    }

    private func nonLeaderboardBanner(
        _ reason: MacBenchmarkRawOnlyPresentationReason
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(MacBenchmarkPresentation.nonLeaderboardTitle(reason))
                    .font(AppDesignTokens.Typography.cardTitle)
                Text(MacBenchmarkPresentation.nonLeaderboardDetail(reason))
                    .font(AppDesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, AppDesignTokens.Spacing.compact)
        .accessibilityElement(children: .combine)
    }

    private func environmentGrid(_ raw: MacBenchmarkRawResult) -> some View {
        let duration = raw.completedAt.map { max(0, $0.timeIntervalSince(raw.startedAt)) }
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            environmentItem(
                title: L10n.text("设备", "Device"),
                value: MacBenchmarkPresentation.hardwareSummary(raw.environment),
                symbol: "cpu"
            )
            environmentItem(
                title: L10n.text("耗时", "Duration"),
                value: duration.map(MacBenchmarkPresentation.durationText) ?? "—",
                symbol: "timer"
            )
        }
    }

    private func environmentItem(
        title: String,
        value: String,
        symbol: String
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(AppDesignTokens.Palette.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTypography.body)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(AppDesignTokens.Typography.dataValue)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, AppDesignTokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

struct MacBenchmarkComponentGrid: View {
    let result: MacBenchmarkResult

    private let columns = [
        GridItem(.adaptive(minimum: 270, maximum: 340), spacing: 12, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("六项结果", "Six Results"), systemImage: "square.grid.3x2")
                    .font(AppDesignTokens.Typography.sectionTitle)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(MacBenchmarkPresentation.componentRows(result), id: \.component) { row in
                    componentCard(row)
                }
            }

            Divider()
        }
        .padding(.horizontal, AppDesignTokens.Spacing.compact)
        .padding(.vertical, AppDesignTokens.Spacing.small)
    }

    private func componentCard(_ row: MacBenchmarkComponentPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: MacBenchmarkPresentation.componentSymbol(row.component))
                    .foregroundStyle(AppDesignTokens.Palette.primary)
                Text(MacBenchmarkPresentation.componentTitle(row.component, unit: row.unit))
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
            }

            if let score = row.score {
                MacBenchmarkScoreSummary(
                    score: score,
                    reference: MacBenchmarkScoring.referenceScore
                )
            } else {
                Text(L10n.text("仅显示原始值", "Raw metrics only"))
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
            }

            valueRow(
                title: L10n.text("实测", "Measured"),
                value: MacBenchmarkPresentation.metricText(
                    row.medianValue,
                    unit: row.unit
                )
            )
            valueRow(
                title: L10n.text("稳定性", "Stability"),
                value: [
                    MacBenchmarkPresentation.variabilityText(row.coefficientOfVariation),
                    MacBenchmarkPresentation.confidenceText(
                    row.confidence,
                    relativeMAD: row.relativeMedianAbsoluteDeviation
                    )
                ].joined(separator: " · ")
            )
            if let capacity = MacBenchmarkPresentation.capacityScoreDetail(
                for: row.component,
                result: result
            ) {
                valueRow(
                    title: L10n.text("容量计分", "Capacity Score"),
                    value: capacity
                )
            }
        }
        .padding(.vertical, AppDesignTokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func valueRow(title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 8)
                Text(value)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .fixedSize()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(AppDesignTokens.Typography.secondary)
    }
}

private struct MacBenchmarkScoreSummary: View {
    let score: Double
    let reference: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MacBenchmarkPresentation.scoreText(score))
                    .font(AppDesignTokens.Typography.metricValue)
                    .monospacedDigit()

                Text(differenceText)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(differenceTint)

                Spacer(minLength: 6)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppDesignTokens.Palette.secondary.opacity(0.18))

                    Capsule()
                        .fill(differenceTint.gradient)
                        .frame(width: barWidth(in: geometry.size.width))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("与基准比较", "Compared with reference"))
        .accessibilityValue(
            L10n.text(
                "本机 \(MacBenchmarkPresentation.scoreText(score))，基准 \(MacBenchmarkPresentation.scoreText(reference))，\(differenceText)",
                "This Mac \(MacBenchmarkPresentation.scoreText(score)), reference \(MacBenchmarkPresentation.scoreText(reference)), \(differenceText)"
            )
        )
    }

    private var ratio: Double {
        guard reference > 0 else { return 0 }
        return min(max(score / reference, 0), 1.25)
    }

    private func barWidth(in totalWidth: CGFloat) -> CGFloat {
        totalWidth * CGFloat(min(ratio, 1))
    }

    private var differenceRatio: Double {
        guard reference > 0 else { return 0 }
        return (score / reference) - 1
    }

    private var differenceText: String {
        let percentage = abs(differenceRatio).formatted(
            .percent.precision(.fractionLength(1))
        )
        if differenceRatio > 0.005 {
            return "+\(percentage)"
        }
        if differenceRatio < -0.005 {
            return "-\(percentage)"
        }
        return L10n.text("持平", "Even")
    }

    private var differenceTint: Color {
        if differenceRatio > 0.005 {
            return AppDesignTokens.Palette.success
        }
        if differenceRatio < -0.005 {
            return AppDesignTokens.Palette.warning
        }
        return AppDesignTokens.Palette.secondary
    }
}

private struct MacBenchmarkScoreComparisonBars: View {
    let score: Double
    let reference: Double

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.small) {
                Text(differenceText)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(differenceTint)
                Spacer(minLength: AppDesignTokens.Spacing.small)
                Text(L10n.text("分数越高越好", "Higher is better"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.tertiary)
            }

            comparisonRow(
                title: L10n.text("本机", "This Mac"),
                value: score,
                tint: differenceTint
            )
            comparisonRow(
                title: L10n.text("基准", "Reference"),
                value: reference,
                tint: AppDesignTokens.Palette.secondary
            )
        }
    }

    private func comparisonRow(title: String, value: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.compact) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(MacBenchmarkPresentation.scoreText(value))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(AppDesignTokens.Typography.secondary)

            ProgressView(value: value, total: scale)
                .progressViewStyle(.linear)
                .tint(tint)
        }
    }

    private var scale: Double {
        max(score, reference)
    }

    private var differenceRatio: Double {
        (score / reference) - 1
    }

    private var differenceText: String {
        let percentage = abs(differenceRatio).formatted(
            .percent.precision(.fractionLength(1))
        )
        if differenceRatio > 0.005 {
            return L10n.text("高于基准 \(percentage)", "Above reference by \(percentage)")
        }
        if differenceRatio < -0.005 {
            return L10n.text("低于基准 \(percentage)", "Below reference by \(percentage)")
        }
        return L10n.text("接近基准", "Near reference")
    }

    private var differenceTint: Color {
        if differenceRatio > 0.005 {
            return AppDesignTokens.Palette.success
        }
        if differenceRatio < -0.005 {
            return AppDesignTokens.Palette.warning
        }
        return AppDesignTokens.Palette.secondary
    }
}

struct MacBenchmarkHistorySection: View {
    let results: [MacBenchmarkResult]

    private struct HistoryRow: Identifiable {
        let id: Int
        let result: MacBenchmarkResult
    }

    private var rows: [HistoryRow] {
        results
            .filter { $0.rawResult?.completedAt != nil }
            .sorted {
                ($0.rawResult?.completedAt ?? .distantPast)
                    > ($1.rawResult?.completedAt ?? .distantPast)
            }
            .prefix(6)
            .enumerated()
            .map { HistoryRow(id: $0.offset, result: $0.element) }
    }

    @ViewBuilder
    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        L10n.text("最近结果", "Recent Results"),
                        systemImage: AppSymbols.Benchmark.history
                    )
                    .font(AppDesignTokens.Typography.sectionTitle)
                    Spacer()
                    Text(L10n.text("最多 6 条", "Up to 6"))
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.tertiary)
                }

                Table(rows) {
                    TableColumn(L10n.text("时间", "Date")) { row in
                        Text(completedAtText(row.result))
                            .monospacedDigit()
                    }
                    .width(min: 150, ideal: 180)

                    TableColumn(L10n.text("设备", "Device")) { row in
                        Text(deviceText(row.result))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .width(min: 150, ideal: 240)

                    TableColumn(MacBenchmarkPresentation.performanceIndexTitle) { row in
                        Text(MacBenchmarkPresentation.scoreText(
                            MacBenchmarkPresentation.displayScore(for: row.result)?.overallScore
                        ))
                            .monospacedDigit()
                    }
                    .width(min: 86, ideal: 110)

                    TableColumn(L10n.text("状态", "Status")) { row in
                        Text(statusText(row.result))
                            .foregroundStyle(row.result.overallScore == nil ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .width(min: 140, ideal: 220)
                }
                .frame(height: tableHeight)

                Divider()
            }
            .padding(.horizontal, AppDesignTokens.Spacing.compact)
            .padding(.vertical, AppDesignTokens.Spacing.small)
        }
    }

    private var tableHeight: CGFloat {
        CGFloat(34 + (rows.count * 30))
    }

    private func completedAtText(_ result: MacBenchmarkResult) -> String {
        result.rawResult?.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    private func deviceText(_ result: MacBenchmarkResult) -> String {
        result.rawResult?.environment.chipName ?? L10n.text("未知设备", "Unknown Device")
    }

    private func statusText(_ result: MacBenchmarkResult) -> String {
        if let reason = MacBenchmarkPresentation.rawOnlyReason(for: result) {
            if MacBenchmarkPresentation.displayScore(for: result) != nil {
                return MacBenchmarkPresentation.nonLeaderboardTitle(reason)
            }
            return MacBenchmarkPresentation.rawOnlyTitle(reason)
        }
        return MacBenchmarkPresentation.referenceSummary(for: result)
    }
}
