import Foundation

enum LaunchdScanLocation: Hashable, Sendable {
    case userLaunchAgents
    case globalLaunchAgents
    case systemLaunchAgents
    case launchDaemons
    case systemLaunchDaemons
    case custom(directory: URL, kind: StartupItemsDomain.ItemKind, scope: StartupItemsDomain.Scope)

    func directory(in context: StartupScanContext) -> URL {
        switch self {
        case .userLaunchAgents:
            context.homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        case .globalLaunchAgents:
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)
        case .systemLaunchAgents:
            URL(fileURLWithPath: "/System/Library/LaunchAgents", isDirectory: true)
        case .launchDaemons:
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        case .systemLaunchDaemons:
            URL(fileURLWithPath: "/System/Library/LaunchDaemons", isDirectory: true)
        case let .custom(directory, _, _):
            directory
        }
    }

    var kind: StartupItemsDomain.ItemKind {
        switch self {
        case .userLaunchAgents: .userLaunchAgent
        case .globalLaunchAgents: .globalLaunchAgent
        case .systemLaunchAgents: .systemLaunchAgent
        case .launchDaemons: .launchDaemon
        case .systemLaunchDaemons: .systemLaunchDaemon
        case let .custom(_, kind, _): kind
        }
    }

    var scope: StartupItemsDomain.Scope {
        switch self {
        case .userLaunchAgents: .currentUser
        case .globalLaunchAgents, .launchDaemons: .allUsers
        case .systemLaunchAgents, .systemLaunchDaemons: .system
        case let .custom(_, _, scope): scope
        }
    }

    var isAppleSystemLocation: Bool {
        switch self {
        case .systemLaunchAgents, .systemLaunchDaemons: true
        default: false
        }
    }
}

enum LaunchdPlistScannerError: LocalizedError, Equatable {
    case inaccessibleDirectory(String, String)

    var errorDescription: String? {
        switch self {
        case let .inaccessibleDirectory(path, reason):
            L10n.text("无法读取启动项目录 \(path)：\(reason)", "Unable to read startup directory \(path): \(reason)")
        }
    }
}

struct LaunchdPlistScanner: StartupItemScanning {
    let location: LaunchdScanLocation
    private let parser: LaunchdPlistParser

    init(location: LaunchdScanLocation, parser: LaunchdPlistParser = LaunchdPlistParser()) {
        self.location = location
        self.parser = parser
    }

    let source = StartupItemsDomain.ScanSource.launchdPlist

    var coverageIdentifier: String {
        switch location {
        case .userLaunchAgents: "launchd.user-agents"
        case .globalLaunchAgents: "launchd.global-agents"
        case .systemLaunchAgents: "launchd.system-agents"
        case .launchDaemons: "launchd.daemons"
        case .systemLaunchDaemons: "launchd.system-daemons"
        case let .custom(directory, _, _): "launchd.custom:\(directory.standardizedFileURL.path)"
        }
    }

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate] {
        if location.isAppleSystemLocation, !context.includeAppleSystemItems { return [] }
        try Task.checkCancellation()
        let directory = location.directory(in: context).standardizedFileURL

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw LaunchdPlistScannerError.inaccessibleDirectory(directory.path, "not a directory")
        }

        let URLs: [URL]
        do {
            URLs = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw LaunchdPlistScannerError.inaccessibleDirectory(directory.path, error.localizedDescription)
        }

        var candidates = [StartupItemsDomain.Candidate]()
        candidates.reserveCapacity(URLs.count)
        for URL in URLs.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            try Task.checkCancellation()
            guard URL.pathExtension.caseInsensitiveCompare("plist") == .orderedSame else { continue }
            candidates.append(candidate(at: URL, directory: directory))
        }
        return candidates
    }

    private func candidate(at plistURL: URL, directory: URL) -> StartupItemsDomain.Candidate {
        let normalizedURL = plistURL.standardizedFileURL
        let management = managementState
        let action = actionCapability
        do {
            let configuration = try parser.parse(
                data: Data(contentsOf: normalizedURL, options: [.mappedIfSafe]),
                plistURL: normalizedURL
            )
            let label = configuration.label
                ?? normalizedURL.deletingPathExtension().lastPathComponent
            var evidence = [
                "launchd-plist",
                "scan-root:\(directory.path)",
            ]
            if configuration.issues.contains(.missingLabel) { evidence.append("missing-label") }
            if configuration.issues.contains(.missingExecutable) { evidence.append("missing-executable") }
            if let executableURL = configuration.resolvedExecutableURL,
               FileManager.default.fileExists(atPath: executableURL.path) == false {
                evidence.append("target-missing")
            }
            if location.isAppleSystemLocation { evidence.append("apple-system-location") }

            return StartupItemsDomain.Candidate(
                id: "launchd:\(normalizedURL.path)",
                source: .launchdPlist,
                kind: location.kind,
                scope: location.scope,
                name: label,
                label: configuration.label,
                plistURL: normalizedURL,
                executableURL: configuration.resolvedExecutableURL,
                applicationURL: Self.enclosingApplicationURL(configuration.resolvedExecutableURL),
                configuration: configuration,
                state: StartupItemsDomain.State(
                    registration: .discoveredFromFile,
                    authorization: location.isAppleSystemLocation ? .notApplicable : .unknown,
                    // `Disabled` in a plist is only a default. A persistent
                    // launchctl override is authoritative and is merged by the
                    // runtime scanner. Until that query succeeds, absence of
                    // the key must remain unknown rather than being presented
                    // as a verified enabled state.
                    enablement: configuration.disabled.map { $0 ? .disabled : .enabled } ?? .unknown,
                    load: .unknown,
                    process: .unknown,
                    management: management
                ),
                attribution: nil,
                actionCapability: action,
                diagnosticEvidence: evidence
            )
        } catch {
            return StartupItemsDomain.Candidate(
                id: "launchd:\(normalizedURL.path)",
                source: .launchdPlist,
                kind: location.kind,
                scope: location.scope,
                name: normalizedURL.deletingPathExtension().lastPathComponent,
                label: nil,
                plistURL: normalizedURL,
                executableURL: nil,
                applicationURL: nil,
                configuration: nil,
                state: StartupItemsDomain.State(
                    registration: .discoveredFromFile,
                    authorization: .unknown,
                    enablement: .unknown,
                    load: .unknown,
                    process: .unknown,
                    management: management
                ),
                attribution: nil,
                actionCapability: action,
                diagnosticEvidence: [
                    "launchd-plist",
                    "scan-root:\(directory.path)",
                    "malformed-plist:\(error.localizedDescription)",
                ]
            )
        }
    }

    private var managementState: StartupItemsDomain.ManagementState {
        switch location.scope {
        case .currentUser: .directlyManageable
        case .allUsers: .requiresAdministrator
        case .system: .systemProtected
        case .managed: .managedByOrganization
        case .applicationBundle, .unknown: .readOnly
        }
    }

    private var actionCapability: StartupItemsDomain.ActionCapability {
        switch location.scope {
        case .currentUser:
            StartupItemsDomain.ActionCapability(
                canEnableDirectly: true,
                canDisableDirectly: true,
                canStopCurrentSession: true,
                canOpenSystemSettings: true,
                canRevealInFinder: true,
                canOpenParentApp: true,
                canRemoveOrphan: true,
                requiresAdministrator: false,
                isReadOnly: false,
                isManaged: false
            )
        case .allUsers:
            StartupItemsDomain.ActionCapability(
                canEnableDirectly: false,
                canDisableDirectly: false,
                canStopCurrentSession: false,
                canOpenSystemSettings: true,
                canRevealInFinder: true,
                canOpenParentApp: true,
                canRemoveOrphan: false,
                requiresAdministrator: true,
                isReadOnly: true,
                isManaged: false
            )
        default:
            .readOnly
        }
    }

    private static func enclosingApplicationURL(_ executableURL: URL?) -> URL? {
        guard let executableURL else { return nil }
        let components = executableURL.standardizedFileURL.pathComponents
        guard let index = components.lastIndex(where: {
            ($0 as NSString).pathExtension.caseInsensitiveCompare("app") == .orderedSame
        }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])), isDirectory: true)
    }
}
