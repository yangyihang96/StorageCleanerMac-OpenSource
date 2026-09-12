import Foundation

struct OrphanedItemScanner: StartupItemScanning {
    private let pathValidator: StartupPathValidator

    init(pathValidator: StartupPathValidator = StartupPathValidator()) {
        self.pathValidator = pathValidator
    }

    let source = StartupItemsDomain.ScanSource.orphanDetection
    let coverageIdentifier = "orphaned-startup-item.evidence"

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate] {
        var result = [StartupItemsDomain.Candidate]()
        result.reserveCapacity(context.seedCandidates.count)
        for candidate in context.seedCandidates {
            try Task.checkCancellation()
            if let orphan = orphan(from: candidate) { result.append(orphan) }
        }
        return result
    }

    private func orphan(from seed: StartupItemsDomain.Candidate) -> StartupItemsDomain.Candidate? {
        guard seed.state.registration != .notRegistered,
              seed.plistURL != nil,
              let executableURL = seed.executableURL else { return nil }
        let inspection = pathValidator.inspect(executableURL)
        guard !inspection.exists, !Self.isOnUnmountedExternalVolume(executableURL) else { return nil }

        // Phase 1 is read-only. Removal is deliberately unavailable until the
        // quarantine + undo store is wired by the management phase.
        let action = StartupItemsDomain.ActionCapability.readOnly

        return StartupItemsDomain.Candidate(
            id: "orphan:\(seed.id)",
            source: .orphanDetection,
            kind: .orphanedItem,
            scope: seed.scope,
            name: seed.name,
            label: seed.label,
            plistURL: seed.plistURL,
            executableURL: executableURL,
            applicationURL: seed.applicationURL,
            configuration: seed.configuration,
            state: StartupItemsDomain.State(
                registration: seed.state.registration,
                authorization: seed.state.authorization,
                enablement: seed.state.enablement,
                load: seed.state.load,
                process: seed.state.process,
                management: .readOnly
            ),
            attribution: seed.attribution,
            actionCapability: action,
            diagnosticEvidence: ["orphan-evidence:target-missing", "source-candidate:\(seed.id)"]
        )
    }

    private static func isOnUnmountedExternalVolume(_ URL: URL) -> Bool {
        let components = URL.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return false }
        let volumeRoot = NSString.path(withComponents: Array(components.prefix(3)))
        var isDirectory: ObjCBool = false
        return !FileManager.default.fileExists(atPath: volumeRoot, isDirectory: &isDirectory)
    }
}
