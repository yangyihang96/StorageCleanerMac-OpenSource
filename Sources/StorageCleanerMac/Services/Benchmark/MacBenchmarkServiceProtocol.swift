import Foundation

struct MacBenchmarkProgress: Equatable, Sendable {
    let stage: BenchmarkStage
    let completedSampleCount: Int
    let totalSampleCount: Int
    let progress: Double
    let elapsedSeconds: Double
}

protocol MacBenchmarkServicing: Sendable {
    func run(
        profile: BenchmarkProfile,
        progress: @escaping @Sendable (MacBenchmarkProgress) async -> Void
    ) async -> MacBenchmarkRawResult
}
