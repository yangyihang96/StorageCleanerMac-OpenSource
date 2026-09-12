import Foundation

/// A file in PrivilegedHelperTools is not startup evidence by itself. This
/// scanner emits a component only when an already-discovered launchd or BTM
/// record refers to the helper.
struct PrivilegedHelperScanner: StartupItemScanning {
    let directory: URL

    init(directory: URL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true)) {
        self.directory = directory.standardizedFileURL
    }

    let source = StartupItemsDomain.ScanSource.privilegedHelper
    var coverageIdentifier: String { "privileged-helper.registered-evidence" }

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate] {
        let rootPath = directory.path + "/"
        var result = [StartupItemsDomain.Candidate]()
        result.reserveCapacity(context.seedCandidates.count)
        for seed in context.seedCandidates {
            try Task.checkCancellation()
            guard let executable = seed.executableURL?.standardizedFileURL,
                  executable.path.hasPrefix(rootPath) else { continue }
            result.append(
                StartupItemsDomain.Candidate(
                    id: "privileged-helper:\(executable.path)",
                    source: .privilegedHelper,
                    kind: .privilegedHelper,
                    scope: .allUsers,
                    name: seed.name,
                    label: seed.label,
                    plistURL: seed.plistURL,
                    executableURL: executable,
                    applicationURL: seed.applicationURL,
                    configuration: seed.configuration,
                    state: StartupItemsDomain.State(
                        registration: seed.state.registration,
                        authorization: seed.state.authorization,
                        enablement: seed.state.enablement,
                        load: seed.state.load,
                        process: seed.state.process,
                        management: .requiresAdministrator
                    ),
                    attribution: seed.attribution,
                    actionCapability: StartupItemsDomain.ActionCapability(
                        canEnableDirectly: false,
                        canDisableDirectly: false,
                        canStopCurrentSession: false,
                        canOpenSystemSettings: true,
                        canRevealInFinder: true,
                        canOpenParentApp: seed.applicationURL != nil,
                        canRemoveOrphan: false,
                        requiresAdministrator: true,
                        isReadOnly: true,
                        isManaged: false
                    ),
                    diagnosticEvidence: ["privileged-helper", "corresponding-startup-record:\(seed.id)"]
                )
            )
        }
        return result
    }
}
