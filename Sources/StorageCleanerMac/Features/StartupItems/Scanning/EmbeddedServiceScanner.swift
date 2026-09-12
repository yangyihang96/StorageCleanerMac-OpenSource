import Foundation

struct EmbeddedServiceScanner: StartupItemScanning {
    private let parser: LaunchdPlistParser

    init(parser: LaunchdPlistParser = LaunchdPlistParser()) {
        self.parser = parser
    }

    let source = StartupItemsDomain.ScanSource.embeddedService
    let coverageIdentifier = "application-bundles.embedded-startup-services"

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate] {
        let applications = Self.applicationURLs(in: context.applicationDirectories)
        var discovered = [StartupItemsDomain.Candidate]()
        for applicationURL in applications {
            try Task.checkCancellation()
            discovered.append(contentsOf: candidates(in: applicationURL, seed: context.seedCandidates))
        }
        return discovered
    }

    private func candidates(
        in applicationURL: URL,
        seed: [StartupItemsDomain.Candidate]
    ) -> [StartupItemsDomain.Candidate] {
        let contents = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let library = contents.appendingPathComponent("Library", isDirectory: true)
        let bundle = Bundle(url: applicationURL)
        let applicationIdentifier = bundle?.bundleIdentifier
        let applicationName = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)?.trimmed.nonEmpty
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)?.trimmed.nonEmpty
            ?? applicationURL.deletingPathExtension().lastPathComponent
        let baseAttribution = StartupItemsDomain.Attribution(
            applicationBundleIdentifier: applicationIdentifier,
            applicationURL: applicationURL,
            applicationName: applicationName,
            developerName: nil,
            teamIdentifier: nil,
            designatedRequirement: nil,
            evidence: [
                StartupItemsDomain.AttributionEvidence(
                    kind: .embeddedInApplication,
                    value: applicationURL.path,
                    confidence: .verified
                ),
            ]
        )

        var result = [StartupItemsDomain.Candidate]()
        let launchDirectories = ["LaunchAgents", "LaunchDaemons"]
        for directoryName in launchDirectories {
            let directory = library.appendingPathComponent(directoryName, isDirectory: true)
            guard let URLs = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for plistURL in URLs where plistURL.pathExtension.caseInsensitiveCompare("plist") == .orderedSame {
                let normalized = plistURL.standardizedFileURL
                guard let data = try? Data(contentsOf: normalized),
                      let configuration = try? parser.parse(
                          data: data,
                          plistURL: normalized,
                          applicationBundleURL: applicationURL
                      ) else { continue }
                let isRegistered = Self.isRegistered(
                    label: configuration.label,
                    executableURL: configuration.resolvedExecutableURL,
                    bundleIdentifier: applicationIdentifier,
                    seed: seed
                )
                result.append(
                    embeddedCandidate(
                        id: "embedded-plist:\(normalized.path)",
                        name: configuration.label ?? normalized.deletingPathExtension().lastPathComponent,
                        label: configuration.label,
                        plistURL: normalized,
                        executableURL: configuration.resolvedExecutableURL,
                        configuration: configuration,
                        applicationURL: applicationURL,
                        attribution: baseAttribution,
                        registered: isRegistered,
                        evidence: ["embedded-\(directoryName.lowercased())"]
                    )
                )
            }
        }

        let loginItemsDirectory = library.appendingPathComponent("LoginItems", isDirectory: true)
        if let helperURLs = try? FileManager.default.contentsOfDirectory(
            at: loginItemsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for helperURL in helperURLs where helperURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                let helperBundle = Bundle(url: helperURL)
                let helperIdentifier = helperBundle?.bundleIdentifier
                let helperName = (helperBundle?.infoDictionary?["CFBundleDisplayName"] as? String)?.trimmed.nonEmpty
                    ?? (helperBundle?.infoDictionary?["CFBundleName"] as? String)?.trimmed.nonEmpty
                    ?? helperURL.deletingPathExtension().lastPathComponent
                let isRegistered = Self.isRegistered(
                    label: helperIdentifier,
                    executableURL: helperBundle?.executableURL,
                    bundleIdentifier: helperIdentifier,
                    seed: seed
                )
                result.append(
                    embeddedCandidate(
                        id: "embedded-login-item:\(helperURL.standardizedFileURL.path)",
                        name: helperName,
                        label: helperIdentifier,
                        plistURL: nil,
                        executableURL: helperBundle?.executableURL,
                        configuration: nil,
                        applicationURL: applicationURL,
                        attribution: baseAttribution,
                        registered: isRegistered,
                        evidence: ["embedded-login-item"]
                    )
                )
            }
        }
        return result
    }

    private func embeddedCandidate(
        id: String,
        name: String,
        label: String?,
        plistURL: URL?,
        executableURL: URL?,
        configuration: StartupItemsDomain.LaunchdConfiguration?,
        applicationURL: URL,
        attribution: StartupItemsDomain.Attribution,
        registered: Bool,
        evidence: [String]
    ) -> StartupItemsDomain.Candidate {
        StartupItemsDomain.Candidate(
            id: id,
            source: .embeddedService,
            kind: .embeddedHelper,
            scope: .applicationBundle,
            name: name,
            label: label,
            plistURL: plistURL,
            executableURL: executableURL,
            applicationURL: applicationURL,
            configuration: configuration,
            state: StartupItemsDomain.State(
                registration: registered ? .registered : .notRegistered,
                authorization: registered ? .unknown : .notApplicable,
                enablement: registered ? .enabled : .unknown,
                load: .unknown,
                process: .unknown,
                management: registered ? .manageableInSystemSettings : .readOnly
            ),
            attribution: attribution,
            actionCapability: StartupItemsDomain.ActionCapability(
                canEnableDirectly: false,
                canDisableDirectly: false,
                canStopCurrentSession: false,
                canOpenSystemSettings: registered,
                canRevealInFinder: true,
                canOpenParentApp: true,
                canRemoveOrphan: false,
                requiresAdministrator: false,
                isReadOnly: true,
                isManaged: false
            ),
            diagnosticEvidence: evidence + [registered ? "registered-evidence-found" : "embedded-not-registered"]
        )
    }

    private static func isRegistered(
        label: String?,
        executableURL: URL?,
        bundleIdentifier: String?,
        seed: [StartupItemsDomain.Candidate]
    ) -> Bool {
        seed.contains { candidate in
            if let label, candidate.label == label { return true }
            if let executableURL,
               candidate.executableURL?.standardizedFileURL == executableURL.standardizedFileURL { return true }
            if let bundleIdentifier,
               candidate.attribution?.applicationBundleIdentifier == bundleIdentifier,
               candidate.state.registration == .registered { return true }
            return false
        }
    }

    private static func applicationURLs(in directories: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var result = [URL]()
        for root in directories {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let URL = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }
                if URL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                    let normalized = URL.standardizedFileURL
                    if seen.insert(normalized.path).inserted { result.append(normalized) }
                    enumerator.skipDescendants()
                }
            }
        }
        return result
    }
}
