import FileOperationShared
import Foundation

enum BackgroundTaskManagementScanError: LocalizedError, Equatable {
    case unavailable
    case restricted(String)
    /// D177: no helper of this build answered, so the default scan could not
    /// read the list; the startup page's Full Scan still can.
    case helperUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            L10n.text("当前系统没有可用的后台任务诊断工具。", "The background-task diagnostic tool is not available on this system.")
        case let .restricted(detail):
            L10n.text("后台任务诊断受系统授权限制：\(detail)", "Background-task diagnostics are restricted by system authorization: \(detail)")
        case .helperUnavailable:
            L10n.text("后台助手没有运行或不是当前版本，登录项要用“完整扫描”读取。", "The background helper is not running or is from another build; use Full Scan to read login items.")
        }
    }
}

/// Where the `sfltool dumpbtm` text comes from.
protocol BackgroundTaskInventoryReading: Sendable {
    func dump(context: StartupScanContext) async throws -> String
}

/// Runs the command in this process. macOS then asks for an administrator
/// password, so it runs only when the scan asks for the diagnostic (the
/// startup page's Full Scan) and in tests.
struct CommandBackgroundTaskInventory: BackgroundTaskInventoryReading {
    let executableURL: URL
    let runner: any StartupCommandRunning

    func dump(context: StartupScanContext) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw BackgroundTaskManagementScanError.unavailable
        }

        let result = try await runner.run(
            executable: executableURL.path,
            arguments: ["dumpbtm"],
            timeout: context.commandTimeout
        )
        try Task.checkCancellation()
        guard result.terminationStatus == 0 else {
            let message = (result.standardError + result.standardOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackgroundTaskManagementScanError.restricted(message.nonEmpty ?? "exit \(result.terminationStatus)")
        }
        // D177: an administrator's dump lists every account; count this one's.
        return BackgroundTaskInventoryFilter.records(in: result.standardOutput, uid: context.currentUserID)
            ?? result.standardOutput
    }
}

/// `sfltool dumpbtm` is an optional, read-only diagnostic source. Its format is
/// not a public data contract, so failures never block the launchd scanners.
/// This scanner must never invoke `resetbtm`.
///
/// D177: the default scanner (`helperBacked()`) reads the list through the
/// privileged helper, without a password dialog and without the opt-in, so
/// login items are counted on every scan (10-23: we showed 0 login items
/// where System Settings and CleanMyMac listed 5). Only the explicit Full
/// Scan falls back to the command here when no helper of this build answers.
struct BackgroundTaskManagementScanner: StartupItemScanning {
    static let defaultExecutableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
    static let commandCoverageIdentifier = "background-task-management.sfltool-dumpbtm"
    static let helperCoverageIdentifier = "background-task-management.helper"

    let executableURL: URL
    private let helper: (any BackgroundTaskInventoryReading)?
    private let command: CommandBackgroundTaskInventory
    private let parser: BTMOutputParser

    init(
        executableURL: URL = Self.defaultExecutableURL,
        runner: any StartupCommandRunning = StructuredStartupCommandRunner(),
        parser: BTMOutputParser = BTMOutputParser()
    ) {
        self.init(helper: nil, executableURL: executableURL, runner: runner, parser: parser)
    }

    /// D177: the coordinator's default; see the type's comment.
    static func helperBacked(
        helper: any BackgroundTaskInventoryReading = HelperBackgroundTaskInventory(),
        executableURL: URL = Self.defaultExecutableURL,
        runner: any StartupCommandRunning = StructuredStartupCommandRunner()
    ) -> Self {
        Self(helper: helper, executableURL: executableURL, runner: runner, parser: BTMOutputParser())
    }

    private init(
        helper: (any BackgroundTaskInventoryReading)?,
        executableURL: URL,
        runner: any StartupCommandRunning,
        parser: BTMOutputParser
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.helper = helper
        command = CommandBackgroundTaskInventory(executableURL: self.executableURL, runner: runner)
        self.parser = parser
        coverageIdentifier = helper == nil ? Self.commandCoverageIdentifier : Self.helperCoverageIdentifier
    }

    let source = StartupItemsDomain.ScanSource.backgroundTaskDiagnostic
    let coverageIdentifier: String

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate] {
        try Task.checkCancellation()
        let output: String
        if let helper {
            do {
                output = try await helper.dump(context: context)
            } catch let error where context.includeBackgroundTaskDiagnostic && !(error is CancellationError) {
                // Only the explicit Full Scan may lead to a password dialog.
                output = try await command.dump(context: context)
            }
        } else {
            guard context.includeBackgroundTaskDiagnostic else { return [] }
            output = try await command.dump(context: context)
        }
        try Task.checkCancellation()
        return parser.parse(output).map(candidate)
    }

    private func candidate(_ record: BTMRecord) -> StartupItemsDomain.Candidate {
        let identifier = record.identifier
            ?? record.bundleIdentifier
            ?? record.uuid?.uuidString
            ?? record.executableURL?.path
            ?? UUID().uuidString
        let applicationIdentifier = record.parentIdentifier ?? record.bundleIdentifier
        let attribution = StartupItemsDomain.Attribution(
            applicationBundleIdentifier: applicationIdentifier,
            applicationURL: Self.enclosingApplicationURL(record.executableURL),
            applicationName: record.name,
            developerName: record.developerName,
            teamIdentifier: record.teamIdentifier,
            designatedRequirement: nil,
            evidence: [
                StartupItemsDomain.AttributionEvidence(
                    kind: .backgroundTaskManagement,
                    value: identifier,
                    confidence: .verified
                ),
            ]
        )

        let isManaged = record.disposition.contains("managed")
        return StartupItemsDomain.Candidate(
            id: "btm:\(identifier)",
            source: .backgroundTaskDiagnostic,
            kind: isManaged ? .managedItem : Self.kind(from: record),
            scope: isManaged ? .managed : .currentUser,
            name: record.name ?? record.bundleIdentifier ?? record.identifier ?? L10n.text("未知后台项目", "Unknown Background Item"),
            label: record.identifier,
            plistURL: nil,
            executableURL: record.executableURL,
            applicationURL: attribution.applicationURL,
            configuration: nil,
            state: StartupItemsDomain.State(
                registration: record.registrationState,
                authorization: isManaged ? .managed : record.authorizationState,
                enablement: record.enablementState,
                load: .unknown,
                process: .unknown,
                management: isManaged ? .managedByOrganization : .manageableInSystemSettings
            ),
            attribution: attribution,
            actionCapability: StartupItemsDomain.ActionCapability(
                canEnableDirectly: false,
                canDisableDirectly: false,
                canStopCurrentSession: false,
                canOpenSystemSettings: true,
                canRevealInFinder: record.executableURL != nil,
                canOpenParentApp: attribution.applicationURL != nil,
                canRemoveOrphan: false,
                requiresAdministrator: false,
                isReadOnly: true,
                isManaged: isManaged
            ),
            diagnosticEvidence: [
                "sfltool-dumpbtm",
                "diagnostic-evidence-only",
                "third-party-management-in-system-settings",
            ] + (record.parentIdentifier.map { ["btm-parent-identifier:\($0)"] } ?? [])
        )
    }

    private static func kind(from record: BTMRecord) -> StartupItemsDomain.ItemKind {
        let type = record.itemType?.lowercased() ?? ""
        if (type == "app" || type.hasPrefix("app ")),
           record.enablementState == .enabled {
            return .openAtLogin
        }
        if type.contains("login") { return .loginItem }
        if type.contains("daemon") { return .launchDaemon }
        if type.contains("agent") { return .userLaunchAgent }
        return .appBackgroundTask
    }

    private static func enclosingApplicationURL(_ URL: URL?) -> URL? {
        guard let URL else { return nil }
        let components = URL.standardizedFileURL.pathComponents
        guard let index = components.lastIndex(where: {
            ($0 as NSString).pathExtension.caseInsensitiveCompare("app") == .orderedSame
        }) else { return nil }
        return Foundation.URL(
            fileURLWithPath: NSString.path(withComponents: Array(components[...index])),
            isDirectory: true
        )
    }
}
