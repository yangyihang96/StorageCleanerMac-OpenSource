import Foundation

/// Frozen before any installation/quit effect, and persisted with the intent.
/// Recovery never substitutes a rescan's versions or a shorter artifact list.
struct ApplicationUpdateArtifactEvidence: Codable, Hashable, Sendable {
    let path: String
    let originalIdentity: ApplicationIdentity
    let originalVersion: ApplicationVersion
    let wasRunning: Bool
}

struct ApplicationUpdateRecoveryEvidence: Codable, Hashable, Sendable {
    let applicationPath: String
    let homebrewMetadata: HomebrewPackageMetadata?
    let artifacts: [ApplicationUpdateArtifactEvidence]
    var reopenOutcomes: [String: String] = [:]
    var commandCompletion: AppUpdateCommandCompletionEvidence?
    var packageVersionsBefore: String?

    var pendingReopenPaths: [String] {
        artifacts.filter { $0.wasRunning && reopenOutcomes[$0.path] == nil }.map(\.path).sorted()
    }

    static func reopening(_ evidence: Self?, using runtime: ApplicationUpdateBatchRuntime) async -> (Self?, String) {
        guard let evidence else { return (nil, "") }
        let (reopened, detail) = await evidence.reopening(using: runtime)
        return (reopened, detail)
    }

    func reopening(using runtime: ApplicationUpdateBatchRuntime) async -> (Self, String) {
        var evidence = self
        var details = [String]()
        for path in pendingReopenPaths {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let detail: String
            if await runtime.isRunning(url) {
                detail = L10n.text("已在运行：", "Already running: ") + path
            } else {
                do { try await runtime.reopen(url); detail = L10n.text("已重开：", "Reopened: ") + path }
                catch { detail = L10n.text("重开失败：", "Reopen failed: ") + path + " · " + AppUpdateErrorRedaction.text(error.localizedDescription) }
            }
            evidence.reopenOutcomes[path] = detail
            details.append(detail)
        }
        return (evidence, details.isEmpty ? "" : "\n" + details.joined(separator: "\n"))
    }
}

extension ApplicationUpdateTask {
    func isolates(_ application: InstalledApplication) -> Bool {
        guard requiresInstallationReconciliation else { return false }
        if application.id == applicationID { return true }
        // Missing package scope in an old Homebrew intent quarantines the
        // provider, including a different bundle row from the same cask.
        if providerIdentifier == .homebrew, recoveryEvidence?.homebrewMetadata == nil,
            application.updateProvider == .homebrew { return true }
        if let frozen = recoveryEvidence?.homebrewMetadata, let current = application.homebrewMetadata,
            frozen.kind == current.kind && frozen.token == current.token { return true }
        if let evidence = recoveryEvidence, !evidence.applicationPath.isEmpty || !evidence.artifacts.isEmpty {
            let key = ApplicationPathNormalizer.comparisonKey(for: application.bundleURL)
            return ([evidence.applicationPath] + evidence.artifacts.map(\.path)).contains {
                ApplicationPathNormalizer.comparisonKey(for: URL(fileURLWithPath: $0)) == key
            }
        }
        // Legacy intents have no path/artifact record. Do not infer permission
        // to install a new scan row with the same frozen application identity.
        return application.identity == originalIdentity
    }
}
