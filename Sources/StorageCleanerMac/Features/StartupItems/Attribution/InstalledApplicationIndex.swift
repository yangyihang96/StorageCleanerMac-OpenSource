import Foundation

struct StartupInstalledApplication: Hashable, Sendable {
    let bundleIdentifier: String?
    let bundleURL: URL
    let executableURL: URL?
    let displayName: String
    let developerName: String?
    let teamIdentifier: String?
    let codeSigningIdentifier: String?
    let designatedRequirement: String?
}

struct InstalledApplicationIndex: Sendable {
    private static let maximumSigningIdentityCandidates = 128
    private static let maximumConcurrentSigningIdentityReads = 4
    private static let ignoredLabelTokens: Set<String> = [
        "com", "org", "net", "io", "app", "agent", "helper", "daemon", "service",
    ]

    let applications: [StartupInstalledApplication]
    let byBundleIdentifier: [String: [StartupInstalledApplication]]
    private let standardizedBundlePaths: [String]
    private let lowercasedBundleIdentifiers: [String?]
    private let applicationByBundlePath: [String: StartupInstalledApplication]
    private let applicationByLabelToken: [String: StartupInstalledApplication]

    init(applications: [StartupInstalledApplication]) {
        self.applications = applications
        byBundleIdentifier = Dictionary(
            grouping: applications.filter { $0.bundleIdentifier?.isEmpty == false },
            by: { $0.bundleIdentifier ?? "" }
        )
        standardizedBundlePaths = applications.map { $0.bundleURL.standardizedFileURL.path }
        lowercasedBundleIdentifiers = applications.map { $0.bundleIdentifier?.lowercased() }

        var applicationsByPath = [String: StartupInstalledApplication]()
        var applicationsByToken = [String: StartupInstalledApplication]()
        for (index, application) in applications.enumerated() {
            let bundlePath = standardizedBundlePaths[index]
            if applicationsByPath[bundlePath] == nil {
                applicationsByPath[bundlePath] = application
            }
            if let token = Self.labelToken(
                application.bundleIdentifier ?? application.displayName
            ), applicationsByToken[token] == nil {
                applicationsByToken[token] = application
            }
        }
        applicationByBundlePath = applicationsByPath
        applicationByLabelToken = applicationsByToken
    }

    func application(at bundleURL: URL) -> StartupInstalledApplication? {
        applicationByBundlePath[bundleURL.standardizedFileURL.path]
    }

    func application(containingExecutableAt executableURL: URL) -> StartupInstalledApplication? {
        let executablePath = executableURL.standardizedFileURL.path
        var bestIndex: Int?
        for index in applications.indices {
            let bundlePath = standardizedBundlePaths[index]
            guard Self.contains(executablePath, in: bundlePath) else { continue }
            if bestIndex.map({ standardizedBundlePaths[$0].count < bundlePath.count }) ?? true {
                bestIndex = index
            }
        }
        return bestIndex.map { applications[$0] }
    }

    func application(matchingBundleLabel label: String) -> StartupInstalledApplication? {
        let normalizedLabel = label.lowercased()
        for index in applications.indices {
            guard let identifier = lowercasedBundleIdentifiers[index] else { continue }
            if normalizedLabel == identifier || normalizedLabel.hasPrefix(identifier + ".") {
                return applications[index]
            }
        }
        return nil
    }

    func application(matchingLabelToken token: String) -> StartupInstalledApplication? {
        applicationByLabelToken[token]
    }

    static func labelToken(_ value: String) -> String? {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .last(where: { $0.count >= 3 && !ignoredLabelTokens.contains(String($0)) })
            .map(String.init)
    }

    private static func contains(_ childPath: String, in parentPath: String) -> Bool {
        childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    static func build(
        directories: [URL]
    ) async -> InstalledApplicationIndex {
        // This method is invoked from the coordinator's structured child task.
        // Keeping the enumeration in that task preserves cancellation; a
        // detached task would continue walking every application directory
        // after the user cancels the scan.
        let URLs = applicationURLs(in: directories)
        var applications = [StartupInstalledApplication]()
        applications.reserveCapacity(URLs.count)
        for URL in URLs {
            guard !Task.isCancelled else { break }
            let application: StartupInstalledApplication? = autoreleasepool {
                guard let bundle = Bundle(url: URL) else { return nil }
                let info = bundle.infoDictionary ?? [:]
                let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)?.trimmed.nonEmpty
                    ?? (info["CFBundleDisplayName"] as? String)?.trimmed.nonEmpty
                    ?? (info[kCFBundleNameKey as String] as? String)?.trimmed.nonEmpty
                    ?? URL.deletingPathExtension().lastPathComponent
                return StartupInstalledApplication(
                    bundleIdentifier: bundle.bundleIdentifier?.trimmed.nonEmpty,
                    bundleURL: URL.standardizedFileURL,
                    executableURL: bundle.executableURL?.standardizedFileURL,
                    displayName: name,
                    developerName: nil,
                    teamIdentifier: nil,
                    codeSigningIdentifier: nil,
                    designatedRequirement: nil
                )
            }
            if let application { applications.append(application) }
        }
        return InstalledApplicationIndex(applications: applications)
    }

    func enrichingSigningIdentities(
        referencedBy candidates: [StartupItemsDomain.Candidate],
        reader: any StartupApplicationSigningIdentityReading = StartupApplicationSigningIdentityReader.shared
    ) async -> InstalledApplicationIndex {
        let bundleIdentifiers = Set(candidates.flatMap { candidate in
            (candidate.configuration?.associatedBundleIdentifiers ?? [])
                + [candidate.attribution?.applicationBundleIdentifier].compactMap { $0 }
        })
        let applicationPaths = Set(candidates.flatMap { candidate in
            [candidate.applicationURL, candidate.attribution?.applicationURL]
                .compactMap { $0?.standardizedFileURL.path }
        })
        let executablePaths = candidates.compactMap { $0.executableURL?.standardizedFileURL.path }
        let labels = candidates.compactMap { $0.label?.lowercased() }
        let targetIndices = Array(applications.indices.filter { index in
            let application = applications[index]
            let bundlePath = standardizedBundlePaths[index]
            if applicationPaths.contains(bundlePath) { return true }
            if let identifier = application.bundleIdentifier {
                if bundleIdentifiers.contains(identifier) { return true }
                let lowercased = identifier.lowercased()
                if labels.contains(where: { $0 == lowercased || $0.hasPrefix(lowercased + ".") }) {
                    return true
                }
            }
            return executablePaths.contains {
                $0 == bundlePath || $0.hasPrefix(bundlePath + "/")
            }
        }.prefix(Self.maximumSigningIdentityCandidates))

        var enriched = applications
        let identities = await Self.signingIdentities(
            applications: applications,
            indices: targetIndices,
            reader: reader
        )
        for index in targetIndices {
            guard !Task.isCancelled else { break }
            let application = enriched[index]
            guard let identity = identities[index] else { continue }
            enriched[index] = StartupInstalledApplication(
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL,
                executableURL: application.executableURL,
                displayName: application.displayName,
                developerName: application.developerName,
                teamIdentifier: identity.teamIdentifier ?? application.teamIdentifier,
                codeSigningIdentifier: identity.codeSigningIdentifier
                    ?? application.codeSigningIdentifier,
                designatedRequirement: identity.designatedRequirement
                    ?? application.designatedRequirement
            )
        }
        return InstalledApplicationIndex(applications: enriched)
    }

    private static func signingIdentities(
        applications: [StartupInstalledApplication],
        indices: [Int],
        reader: any StartupApplicationSigningIdentityReading
    ) async -> [Int: StartupApplicationSigningIdentity] {
        guard !indices.isEmpty else { return [:] }
        return await withTaskGroup(
            of: (Int, StartupApplicationSigningIdentity?).self,
            returning: [Int: StartupApplicationSigningIdentity].self
        ) { group in
            let initialCount = min(maximumConcurrentSigningIdentityReads, indices.count)
            for position in 0..<initialCount {
                let index = indices[position]
                let application = applications[index]
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    return (
                        index,
                        await reader.identity(
                            at: application.bundleURL,
                            executableURL: application.executableURL
                        )
                    )
                }
            }

            var identities = [Int: StartupApplicationSigningIdentity]()
            var nextPosition = initialCount
            while let result = await group.next() {
                let (index, identity) = result
                if let identity { identities[index] = identity }
                guard !Task.isCancelled, nextPosition < indices.count else { continue }

                let nextIndex = indices[nextPosition]
                let application = applications[nextIndex]
                group.addTask {
                    guard !Task.isCancelled else { return (nextIndex, nil) }
                    return (
                        nextIndex,
                        await reader.identity(
                            at: application.bundleURL,
                            executableURL: application.executableURL
                        )
                    )
                }
                nextPosition += 1
            }
            return identities
        }
    }

    private static func applicationURLs(in directories: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var result = [URL]()
        for root in directories.map(\.standardizedFileURL) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let URL = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }
                guard URL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                let normalized = URL.standardizedFileURL
                if seen.insert(normalized.path).inserted { result.append(normalized) }
                enumerator.skipDescendants()
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
