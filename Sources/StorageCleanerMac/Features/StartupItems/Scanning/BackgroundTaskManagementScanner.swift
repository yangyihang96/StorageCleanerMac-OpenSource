import Foundation

enum BackgroundTaskManagementScanError: LocalizedError, Equatable {
    case unavailable
    case restricted(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            L10n.text("当前系统没有可用的后台任务诊断工具。", "The background-task diagnostic tool is not available on this system.")
        case let .restricted(detail):
            L10n.text("后台任务诊断受系统授权限制：\(detail)", "Background-task diagnostics are restricted by system authorization: \(detail)")
        }
    }
}

/// `sfltool dumpbtm` is an optional, read-only diagnostic source. Its format is
/// not a public data contract, so failures never block the launchd scanners.
/// This scanner must never invoke `resetbtm`.
struct BackgroundTaskManagementScanner: StartupItemScanning {
    let executableURL: URL
    private let runner: any StartupCommandRunning
    private let parser: BTMOutputParser

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/sfltool"),
        runner: any StartupCommandRunning = StructuredStartupCommandRunner(),
        parser: BTMOutputParser = BTMOutputParser()
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.runner = runner
        self.parser = parser
    }

    let source = StartupItemsDomain.ScanSource.backgroundTaskDiagnostic
    let coverageIdentifier = "background-task-management.sfltool-dumpbtm"

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate] {
        guard context.includeBackgroundTaskDiagnostic else { return [] }
        try Task.checkCancellation()
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

        return parser.parse(result.standardOutput).map(candidate)
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
