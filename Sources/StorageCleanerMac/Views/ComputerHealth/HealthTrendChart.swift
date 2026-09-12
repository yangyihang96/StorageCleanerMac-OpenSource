import SwiftUI

struct HealthTrendPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let score: Double?
    let coveragePercent: Double

    var id: Date { date }
}

enum HealthTrendSeries {
    static func points(
        current: ComputerHealthEvaluation?,
        history: [ComputerHealthHistoryEntry],
        calendar inputCalendar: Calendar = .current
    ) -> [HealthTrendPoint] {
        guard let current,
              current.evaluatedAt.timeIntervalSinceReferenceDate.isFinite,
              current.coverage.isFinite else {
            return []
        }
        var calendar = inputCalendar
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let cutoff = calendar.date(byAdding: .day, value: -30, to: current.evaluatedAt)
            ?? current.evaluatedAt.addingTimeInterval(-30 * 86_400)
        var newestByDay: [Date: HealthTrendPoint] = [:]
        var timestampByDay: [Date: Date] = [:]

        func include(evaluation: ComputerHealthEvaluation, recordedAt: Date) {
            guard recordedAt.timeIntervalSinceReferenceDate.isFinite,
                  recordedAt >= cutoff,
                  recordedAt <= current.evaluatedAt,
                  evaluation.coverage.isFinite else {
                return
            }
            let day = calendar.startOfDay(for: recordedAt)
            if let existingDate = timestampByDay[day], existingDate > recordedAt {
                return
            }
            let score = evaluation.score.flatMap { value in
                value.isFinite ? min(max(value, 0), 100) : nil
            }
            newestByDay[day] = HealthTrendPoint(
                date: recordedAt,
                score: score,
                coveragePercent: min(max(evaluation.coverage, 0), 1) * 100
            )
            timestampByDay[day] = recordedAt
        }

        for entry in history {
            guard entry.modelVersion == ComputerHealthHistoryEntry.currentModelVersion,
                  entry.evaluation.modelVersion == current.modelVersion else {
                continue
            }
            include(evaluation: entry.evaluation, recordedAt: entry.recordedAt)
        }
        include(evaluation: current, recordedAt: current.evaluatedAt)

        return newestByDay.values.sorted { $0.date < $1.date }
    }
}

struct HealthTrendChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let evaluation: ComputerHealthEvaluation?
    let history: [ComputerHealthHistoryEntry]

    var body: some View {
        let trendPoints = HealthTrendSeries.points(
            current: evaluation,
            history: history
        )
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text("健康趋势", "Health Trend"), systemImage: "chart.xyaxis.line")
                .font(AppDesignTokens.Typography.sectionTitle)

            if trendPoints.count >= 2 {
                chart(points: trendPoints)
                    .frame(height: 148)
                legend(points: trendPoints)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(.secondary)
                    Text(L10n.text(
                        "完成两次检查后显示趋势",
                        "Complete two checks to show a trend"
                    ))
                    .font(AppDesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            }
        }
        .padding(.horizontal, AppDesignTokens.Spacing.compact)
        .padding(.vertical, AppDesignTokens.Spacing.medium)
        .overlay(alignment: .bottom) { Divider() }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private func chart(points: [HealthTrendPoint]) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                HealthTrendGrid()

                HealthTrendLine(
                    dates: points.map(\.date),
                    values: points.map { Optional($0.coveragePercent) }
                )
                    .stroke(
                        AppDesignTokens.Palette.secondary.opacity(0.72),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )

                HealthTrendLine(
                    dates: points.map(\.date),
                    values: points.map(\.score)
                )
                    .stroke(
                        AppDesignTokens.Palette.primary,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )

                ForEach(points) { point in
                    if let score = point.score {
                        Circle()
                            .fill(AppDesignTokens.Palette.primary)
                            .frame(width: 6, height: 6)
                            .position(
                                x: xPosition(
                                    date: point.date,
                                    firstDate: points.first?.date,
                                    lastDate: points.last?.date,
                                    width: proxy.size.width
                                ),
                                y: yPosition(value: score, height: proxy.size.height)
                            )
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("最近 30 天健康分与覆盖率趋势", "Health score and coverage over the last 30 days"))
        .accessibilityValue(accessibilitySummary(points: points))
    }

    private func legend(points: [HealthTrendPoint]) -> some View {
        HStack(spacing: 18) {
            legendItem(
                color: AppDesignTokens.Palette.primary,
                title: L10n.text("健康分", "Health Score"),
                value: points.last?.score.map { "\(Int($0.rounded()))" } ?? "--"
            )
            legendItem(
                color: AppDesignTokens.Palette.secondary,
                title: L10n.text("覆盖率", "Coverage"),
                value: points.last.map { "\(Int($0.coveragePercent.rounded()))%" } ?? "--"
            )
            Spacer()
            if let first = points.first?.date, let last = points.last?.date {
                Text("\(first.formatted(date: .numeric, time: .omitted)) – \(last.formatted(date: .numeric, time: .omitted))")
                    .font(AppTypography.body)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private func legendItem(color: Color, title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(AppDesignTokens.Typography.secondary)
    }

    private func xPosition(
        date: Date,
        firstDate: Date?,
        lastDate: Date?,
        width: CGFloat
    ) -> CGFloat {
        guard let firstDate,
              let lastDate,
              lastDate > firstDate else {
            return width / 2
        }
        let fraction = date.timeIntervalSince(firstDate) / lastDate.timeIntervalSince(firstDate)
        return width * CGFloat(min(max(fraction, 0), 1))
    }

    private func yPosition(value: Double, height: CGFloat) -> CGFloat {
        height * CGFloat(1 - min(max(value, 0), 100) / 100)
    }

    private func accessibilitySummary(points: [HealthTrendPoint]) -> String {
        guard let last = points.last else { return HealthDashboardText.dataInsufficient }
        if let lastScore = last.score {
            let firstScore = points.compactMap(\.score).first ?? lastScore
            return L10n.text(
                "健康分从 \(Int(firstScore.rounded())) 到 \(Int(lastScore.rounded()))，当前覆盖率 \(Int(last.coveragePercent.rounded()))%",
                "Health score changed from \(Int(firstScore.rounded())) to \(Int(lastScore.rounded())); current coverage is \(Int(last.coveragePercent.rounded()))%"
            )
        }
        return L10n.text(
            "当前健康分数据不足，当前覆盖率 \(Int(last.coveragePercent.rounded()))%",
            "The current health score has insufficient data; current coverage is \(Int(last.coveragePercent.rounded()))%"
        )
    }
}

private struct HealthTrendLine: Shape {
    let dates: [Date]
    let values: [Double?]

    func path(in rect: CGRect) -> Path {
        guard !values.isEmpty, dates.count == values.count else { return Path() }
        let firstDate = dates[0]
        let lastDate = dates[dates.count - 1]
        let span = lastDate.timeIntervalSince(firstDate)
        var path = Path()
        var hasOpenSegment = false
        for (index, optionalValue) in values.enumerated() {
            guard let value = optionalValue, value.isFinite else {
                hasOpenSegment = false
                continue
            }
            let fraction = span > 0
                ? dates[index].timeIntervalSince(firstDate) / span
                : 0.5
            let x = rect.minX + rect.width * CGFloat(min(max(fraction, 0), 1))
            let normalized = min(max(value, 0), 100) / 100
            let y = rect.maxY - rect.height * CGFloat(normalized)
            if hasOpenSegment {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
                hasOpenSegment = true
            }
        }
        return path
    }
}

private struct HealthTrendGrid: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                for value in [0.25, 0.5, 0.75] {
                    let y = proxy.size.height * value
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(.secondary.opacity(0.12), lineWidth: 1)
        }
    }
}
