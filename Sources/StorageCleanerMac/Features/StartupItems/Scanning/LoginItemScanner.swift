import Foundation

enum LoginItemScanError: LocalizedError, Equatable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason):
            L10n.text("无法读取当前用户的登录时打开项目：\(reason)", "Unable to read the current user's Open at Login items: \(reason)")
        }
    }
}

/// Uses the structured system profiler payload so opening the page never asks
/// for System Events automation access.
struct LoginItemScanner: StartupItemScanning {
    private let runner: any StartupCommandRunning
    private let systemProfilerURL: URL

    init(
        runner: any StartupCommandRunning = StructuredStartupCommandRunner(),
        systemProfilerURL: URL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    ) {
        self.runner = runner
        self.systemProfilerURL = systemProfilerURL.standardizedFileURL
    }

    let source = StartupItemsDomain.ScanSource.openAtLogin
    let coverageIdentifier = "open-at-login.current-user"

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate] {
        guard FileManager.default.isExecutableFile(atPath: systemProfilerURL.path) else {
            throw LoginItemScanError.unavailable("system_profiler is unavailable")
        }
        let result = try await runner.run(
            executable: systemProfilerURL.path,
            arguments: ["SPLoginItemDataType", "-json"],
            timeout: context.commandTimeout
        )
        guard result.terminationStatus == 0 else {
            let reason = (result.standardError + result.standardOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LoginItemScanError.unavailable(reason.nonEmpty ?? "exit \(result.terminationStatus)")
        }
        try Task.checkCancellation()
        guard let candidates = Self.parseSystemProfilerJSON(result.standardOutput) else {
            throw LoginItemScanError.unavailable("invalid system_profiler output")
        }
        return candidates
    }

    private static func parseSystemProfilerJSON(_ output: String) -> [StartupItemsDomain.Candidate]? {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["SPLoginItemDataType"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            let name = (row["_name"] as? String)?.trimmed.nonEmpty
                ?? (row["name"] as? String)?.trimmed.nonEmpty
            guard let name else { return nil }
            let path = (row["path"] as? String)?.trimmed.nonEmpty
                ?? (row["location"] as? String)?.trimmed.nonEmpty
            let targetURL = path.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let isApplication = targetURL?.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            return StartupItemsDomain.Candidate(
                id: "open-at-login:\(targetURL?.path ?? name)",
                source: .openAtLogin,
                kind: .openAtLogin,
                scope: .currentUser,
                name: name,
                label: nil,
                plistURL: nil,
                executableURL: targetURL,
                applicationURL: isApplication ? targetURL : nil,
                configuration: nil,
                state: StartupItemsDomain.State(
                    registration: .legacyRegistered,
                    authorization: .approved,
                    enablement: .enabled,
                    load: .notLoaded,
                    process: .unknown,
                    management: .manageableInSystemSettings
                ),
                attribution: nil,
                actionCapability: StartupItemsDomain.ActionCapability(
                    canEnableDirectly: false,
                    canDisableDirectly: false,
                    canStopCurrentSession: false,
                    canOpenSystemSettings: true,
                    canRevealInFinder: targetURL != nil,
                    canOpenParentApp: isApplication,
                    canRemoveOrphan: false,
                    requiresAdministrator: false,
                    isReadOnly: true,
                    isManaged: false
                ),
                diagnosticEvidence: ["system-profiler-login-items", "structured-json"]
            )
        }
    }
}
