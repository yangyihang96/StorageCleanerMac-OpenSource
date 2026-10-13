import Foundation

struct MSeriesStageBudget: Equatable, Sendable {
    let id: String
    let plannedSeconds: Double
    let weight: Double
    static let standardV11: [Self] = [
        .init(id: "preflight", plannedSeconds: 5, weight: 5),
        .init(id: "core", plannedSeconds: 180, weight: 180),
        .init(id: "cpuEfficiency", plannedSeconds: 45, weight: 45),
        .init(id: "gpuPeak", plannedSeconds: 35, weight: 35),
        .init(id: "cpuSustained", plannedSeconds: 95, weight: 95),
        .init(id: "gpuSustained", plannedSeconds: 95, weight: 95),
        .init(id: "saving", plannedSeconds: 5, weight: 5)
    ]
    static let pressure10m: [Self] = [
        .init(id: "preflight", plannedSeconds: 5, weight: 5),
        .init(id: "cpuPressure", plannedSeconds: 300, weight: 300),
        .init(id: "gpuPressure", plannedSeconds: 300, weight: 300),
        .init(id: "saving", plannedSeconds: 5, weight: 5)
    ]
    /// The still-shipped v10 runner is not silently presented as a full v11 run.
    static let coreV10: [Self] = [
        .init(id: "preflight", plannedSeconds: 5, weight: 5),
        .init(id: "core", plannedSeconds: 180, weight: 180),
        .init(id: "legacyExtensions", plannedSeconds: 15, weight: 15),
        .init(id: "saving", plannedSeconds: 5, weight: 5)
    ]
}

/// Clock injection keeps presentation deterministic. No measurement loop or timer.
struct MSeriesStageProgress: Equatable, Sendable {
    enum Failure: Error { case invalidBudgets, invalidStage, notSaving }
    let frozenBudgets: [MSeriesStageBudget]
    let startedAtNanoseconds: UInt64
    private(set) var activeIndex = 0
    private(set) var stageStartedAtNanoseconds: UInt64
    private var frozenFraction: Double?
    private var saved = false
    private var minimumFraction = 0.0

    init(budgets: [MSeriesStageBudget], nowNanoseconds: UInt64) throws {
        guard !budgets.isEmpty, Set(budgets.map(\.id)).count == budgets.count,
              budgets.allSatisfy({ !$0.id.isEmpty && $0.plannedSeconds.isFinite && $0.plannedSeconds > 0
                  && $0.weight.isFinite && $0.weight > 0 }), budgets.reduce(0, { $0 + $1.weight }).isFinite else {
            throw Failure.invalidBudgets
        }
        frozenBudgets = budgets
        startedAtNanoseconds = nowNanoseconds
        stageStartedAtNanoseconds = nowNanoseconds
    }
    var activeStage: String { frozenBudgets[activeIndex].id }
    func elapsedSeconds(nowNanoseconds: UInt64) -> Double {
        Double(nowNanoseconds >= startedAtNanoseconds ? nowNanoseconds - startedAtNanoseconds : 0) / 1e9
    }
    func fraction(nowNanoseconds: UInt64) -> Double {
        if saved { return 1 }
        if let frozenFraction { return frozenFraction }
        let completedWeight = frozenBudgets.prefix(activeIndex).reduce(0) { $0 + $1.weight }
        let stage = frozenBudgets[activeIndex]
        let elapsed = Double(nowNanoseconds >= stageStartedAtNanoseconds ? nowNanoseconds - stageStartedAtNanoseconds : 0) / 1e9
        let value = (completedWeight + stage.weight * min(elapsed / stage.plannedSeconds, 1))
            / frozenBudgets.reduce(0) { $0 + $1.weight }
        return min(0.99, max(minimumFraction, value))
    }
    mutating func advance(to stage: String, nowNanoseconds: UInt64) throws {
        guard frozenFraction == nil, !saved, nowNanoseconds >= stageStartedAtNanoseconds,
              let index = frozenBudgets.firstIndex(where: { $0.id == stage }), index >= activeIndex else { throw Failure.invalidStage }
        if index == activeIndex { return }
        minimumFraction = fraction(nowNanoseconds: nowNanoseconds)
        activeIndex = index
        stageStartedAtNanoseconds = nowNanoseconds
    }
    mutating func stop(nowNanoseconds: UInt64) { frozenFraction = fraction(nowNanoseconds: nowNanoseconds) }
    mutating func didSave() throws {
        guard activeStage == "saving", frozenFraction == nil else { throw Failure.notSaving }
        saved = true
    }
}
