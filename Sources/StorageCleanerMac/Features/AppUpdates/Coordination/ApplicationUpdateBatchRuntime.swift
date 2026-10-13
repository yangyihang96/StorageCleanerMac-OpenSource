import AppKit
import Foundation

/// All app lifecycle effects are injected. A refusal is a terminal skip for
/// this item, so an unsaved-document dialog never holds up the entire batch.
struct ApplicationUpdateBatchRuntime: Sendable {
    var isRunning: @Sendable (URL) async -> Bool
    var requestQuit: @Sendable (URL) async -> Bool
    var reopen: @Sendable (URL) async throws -> Void
    var wait: @Sendable () async throws -> Void
    var quitTimeout: Duration = .seconds(60)

    static let system = Self(
        isRunning: { url in await MainActor.run { !applications(at: url).isEmpty } },
        requestQuit: { url in await MainActor.run { applications(at: url).allSatisfy { $0.terminate() } } },
        reopen: { url in
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        },
        wait: { try await Task.sleep(for: .milliseconds(200)) }
    )

    @MainActor private static func applications(at url: URL) -> [NSRunningApplication] {
        let key = ApplicationPathNormalizer.comparisonKey(for: url)
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL.map { ApplicationPathNormalizer.comparisonKey(for: $0) == key } == true && !$0.isTerminated
        }
    }

    func stop(_ app: InstalledApplication) async throws -> (stopped: Bool, wasRunning: Bool) {
        try await stop(app.bundleURL)
    }
    func stop(_ url: URL) async throws -> (stopped: Bool, wasRunning: Bool) {
        let running = await isRunning(url)
        guard running else { return (true, false) }
        guard await requestQuit(url) else { return (false, true) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: quitTimeout)
        while await isRunning(url) {
            try Task.checkCancellation()
            guard clock.now < deadline else { return (false, true) }
            try await wait()
        }
        return (true, true)
    }
}

protocol ApplicationUpdateBatchExecuting: ApplicationUpdateExecuting {
    func beginBatch(applications: [InstalledApplication], sessionID: UUID) async
    func executeHomebrewBatch(applications: [InstalledApplication], tasks: [ApplicationUpdateTask],
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async -> [ApplicationUpdateInstallResult]
    func endBatch(sessionID: UUID) async
}

extension ApplicationUpdatePlan {
    var batchApplicationIDs: [String] {
        automaticApplicationIDs + requiresQuitApplicationIDs + requiresAuthorizationApplicationIDs
    }
    var batchCount: Int { batchApplicationIDs.count }
}

struct AppUpdateBatchPresentation: Equatable, Sendable {
    let count: Int
    let runningCount: Int
    let needsAuthorization: Bool
    init(applications: [InstalledApplication]) {
        let plan = ApplicationUpdatePlanBuilder().build(applications: applications)
        let ids = Set(plan.batchApplicationIDs)
        count = ids.count
        runningCount = Set(applications.filter { ids.contains($0.id) && $0.isRunning }.map(\.id)).count
        needsAuthorization = applications.contains { ids.contains($0.id) && $0.requiresAdministratorAuthorization }
    }
    var title: String { L10n.text("全部更新 · \(count) 个", "Update All · \(count)") }
    var detail: String {
        var parts = [String]()
        if runningCount > 0 {
            parts.append(L10n.text("将退出并重新打开 \(runningCount) 个正在运行的应用", "Quit and reopen \(runningCount) running apps"))
        }
        if needsAuthorization { parts.append(L10n.text("需要一次管理员授权", "One administrator authorization required")) }
        return parts.joined(separator: " · ")
    }
}
