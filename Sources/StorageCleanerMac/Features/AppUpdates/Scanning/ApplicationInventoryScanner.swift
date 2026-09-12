import Foundation

struct ApplicationInventoryScanner: Sendable {
    private static let maximumConcurrentMetadataReads = 4

    private let directoryScanner: DirectoryApplicationScanner
    private let spotlightScanner: SpotlightApplicationScanner
    private let metadataReader: ApplicationMetadataReader
    private let homebrewScanner: HomebrewInventoryScanner
    private let deduplicator: ApplicationDeduplicator
    private let sourceResolver: OfficialUpdateSourceResolver
    private let providerRegistry: ApplicationUpdateProviderRegistry

    init(
        directoryScanner: DirectoryApplicationScanner = DirectoryApplicationScanner(),
        spotlightScanner: SpotlightApplicationScanner = SpotlightApplicationScanner(),
        metadataReader: ApplicationMetadataReader = ApplicationMetadataReader(),
        homebrewScanner: HomebrewInventoryScanner = HomebrewInventoryScanner(),
        deduplicator: ApplicationDeduplicator = ApplicationDeduplicator(),
        sourceResolver: OfficialUpdateSourceResolver = OfficialUpdateSourceResolver(),
        providerRegistry: ApplicationUpdateProviderRegistry = ApplicationUpdateProviderRegistry()
    ) {
        self.directoryScanner = directoryScanner
        self.spotlightScanner = spotlightScanner
        self.metadataReader = metadataReader
        self.homebrewScanner = homebrewScanner
        self.deduplicator = deduplicator
        self.sourceResolver = sourceResolver
        self.providerRegistry = providerRegistry
    }

    func scan(
        configuration: ApplicationScanConfiguration = ApplicationScanConfiguration(),
        onProgress: @escaping @Sendable (ApplicationScanProgress) async -> Void = { _ in },
        onApplications: @escaping @Sendable ([InstalledApplication]) async -> Void = { _ in }
    ) async throws -> [InstalledApplication] {
        try Task.checkCancellation()
        // The signed remote registry is enrichment, not a prerequisite for
        // local discovery. Start it concurrently so standard-directory apps
        // can be emitted immediately even on a slow or unavailable network.
        async let registryWarning = sourceResolver.refreshSources()
        var roots = ApplicationScanConfiguration.standardDirectories()
        roots.append(contentsOf: configuration.additionalDirectories)
        for bookmarkData in configuration.additionalDirectoryBookmarks {
            do {
                roots.append(try ApplicationScanDirectory.resolveSecurityScopedBookmark(
                    bookmarkData,
                    maximumDepth: 6
                ))
            } catch {
                await onProgress(ApplicationScanProgress(
                    stage: .scanningStandardDirectories,
                    detail: "security-scoped-directory: \(error.localizedDescription)"
                ))
            }
        }
        if configuration.includeExternalVolumes {
            roots.append(contentsOf: directoryScanner.externalVolumeDirectories(
                maximumDepth: configuration.externalVolumeMaximumDepth
            ))
        }

        await onProgress(ApplicationScanProgress(stage: .scanningStandardDirectories))
        async let spotlightOutcome = scanSpotlight(configuration: configuration)
        async let homebrewOutcome = scanHomebrew(
            checkSelfUpdatingCasks: configuration.checkSelfUpdatingHomebrewCasks
        )
        let directoryURLs = try await directoryScanner.scan(roots)
        let runningState = await ApplicationRunningStateSnapshot.capture()
        var applications = try await readMetadata(
            urls: directoryURLs,
            runningState: runningState,
            onProgress: onProgress,
            onApplications: onApplications
        )

        let spotlightResult = try await spotlightOutcome
        var additionalURLs = spotlightResult.applicationURLs.filter {
            shouldInclude($0, includeExternalVolumes: configuration.includeExternalVolumes)
        }
        if spotlightResult.completion != .completed {
            await onProgress(ApplicationScanProgress(
                stage: .scanningFallbackDirectories,
                scannedCount: applications.count,
                discoveredCount: directoryURLs.count,
                detail: spotlightResult.completion == .timedOut ? "spotlight-timeout" : "spotlight-unavailable"
            ))
            additionalURLs.append(contentsOf: try await directoryScanner.scan(configuration.fallbackDirectories))
        }
        let knownPaths = Set(applications.map {
            ApplicationPathNormalizer.comparisonKey(for: $0.bundleURL)
        })
        additionalURLs = uniqueURLs(additionalURLs).filter {
            !knownPaths.contains(ApplicationPathNormalizer.comparisonKey(for: $0))
        }
        applications.append(contentsOf: try await readMetadata(
            urls: additionalURLs,
            runningState: runningState,
            onProgress: onProgress,
            onApplications: onApplications
        ))

        let homebrewResult = try await homebrewOutcome
        if let homebrewInventory = homebrewResult.inventory {
            applications = merge(
                homebrewInventory,
                into: applications,
                includeFormulae: configuration.includeHomebrewFormulae
            )
        } else if let errorDescription = homebrewResult.errorDescription {
            await onProgress(ApplicationScanProgress(
                stage: .identifyingSources,
                scannedCount: applications.count,
                discoveredCount: applications.count,
                detail: "homebrew-unavailable: \(errorDescription)"
            ))
        }
        applications = deduplicator.process(applications)

        if let warning = await registryWarning {
            await onProgress(ApplicationScanProgress(
                stage: .identifyingSources,
                detail: "official-registry: \(warning)"
            ))
        }

        await onProgress(ApplicationScanProgress(
            stage: .identifyingSources,
            scannedCount: 0,
            discoveredCount: applications.count
        ))
        var classified = [InstalledApplication]()
        var classifiedBatch = [InstalledApplication]()
        classified.reserveCapacity(applications.count)
        classifiedBatch.reserveCapacity(16)
        for (index, application) in applications.enumerated() {
            try Task.checkCancellation()
            var resolvedApplication = application
            resolvedApplication.officialSource = await sourceResolver.resolve(application)
            let item = await providerRegistry.classify(resolvedApplication)
            classified.append(item)
            classifiedBatch.append(item)
            if classifiedBatch.count == 16 || index == applications.indices.last {
                await onApplications(classifiedBatch)
                classifiedBatch.removeAll(keepingCapacity: true)
            }
            if (index + 1).isMultiple(of: 16) || index == applications.indices.last {
                await onProgress(ApplicationScanProgress(
                    stage: .identifyingSources,
                    scannedCount: index + 1,
                    discoveredCount: applications.count
                ))
            }
        }

        classified = deduplicator.process(classified).sorted {
            if $0.isSystemApplication != $1.isSystemApplication {
                return !$0.isSystemApplication
            }
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.bundleURL.path.localizedStandardCompare($1.bundleURL.path) == .orderedAscending
        }
        await onProgress(ApplicationScanProgress(
            stage: .completed,
            scannedCount: classified.count,
            discoveredCount: classified.count
        ))
        return classified
    }

    private func scanSpotlight(
        configuration: ApplicationScanConfiguration
    ) async throws -> SpotlightApplicationScanResult {
        guard configuration.includeSpotlightResults else {
            return SpotlightApplicationScanResult(applicationURLs: [], completion: .unavailable)
        }
        do {
            return try await spotlightScanner.scan(timeout: configuration.spotlightTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return SpotlightApplicationScanResult(applicationURLs: [], completion: .unavailable)
        }
    }

    private struct HomebrewScanResult: Sendable {
        let inventory: HomebrewInventory?
        let errorDescription: String?
    }

    private func scanHomebrew(checkSelfUpdatingCasks: Bool) async throws -> HomebrewScanResult {
        do {
            return HomebrewScanResult(
                inventory: try await homebrewScanner.scan(
                    includeGreedyCasks: checkSelfUpdatingCasks
                ),
                errorDescription: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return HomebrewScanResult(
                inventory: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    private func readMetadata(
        urls: [URL],
        runningState: ApplicationRunningStateSnapshot,
        onProgress: @escaping @Sendable (ApplicationScanProgress) async -> Void,
        onApplications: @escaping @Sendable ([InstalledApplication]) async -> Void
    ) async throws -> [InstalledApplication] {
        var applications = [InstalledApplication]()
        var incrementalBatch = [InstalledApplication]()
        let urls = uniqueURLs(urls)
        let metadataReader = self.metadataReader
        applications.reserveCapacity(urls.count)
        incrementalBatch.reserveCapacity(16)
        var startIndex = 0
        while startIndex < urls.count {
            try Task.checkCancellation()
            let endIndex = min(
                startIndex + Self.maximumConcurrentMetadataReads,
                urls.count
            )
            let results = try await withThrowingTaskGroup(
                of: (Int, InstalledApplication?).self,
                returning: [(Int, InstalledApplication?)].self
            ) { group in
                for index in startIndex..<endIndex {
                    let url = urls[index]
                    group.addTask {
                        try Task.checkCancellation()
                        let application = await metadataReader.read(
                            applicationURL: url,
                            runningState: runningState
                        )
                        try Task.checkCancellation()
                        return (index, application)
                    }
                }

                var results = [(Int, InstalledApplication?)]()
                results.reserveCapacity(endIndex - startIndex)
                for try await result in group {
                    results.append(result)
                }
                return results.sorted { $0.0 < $1.0 }
            }

            for (_, application) in results {
                if let application {
                    applications.append(application)
                    incrementalBatch.append(application)
                }
                if incrementalBatch.count == 16 {
                    await onApplications(incrementalBatch)
                    incrementalBatch.removeAll(keepingCapacity: true)
                }
            }

            if endIndex.isMultiple(of: 16) || endIndex == urls.count {
                await onProgress(ApplicationScanProgress(
                    stage: .readingMetadata,
                    scannedCount: endIndex,
                    discoveredCount: urls.count
                ))
            }
            startIndex = endIndex
        }
        try Task.checkCancellation()
        if !incrementalBatch.isEmpty {
            await onApplications(incrementalBatch)
        }
        return applications
    }

    private func merge(
        _ inventory: HomebrewInventory,
        into applications: [InstalledApplication],
        includeFormulae: Bool
    ) -> [InstalledApplication] {
        var result = applications
        var matchedTokens = Set<String>()
        for index in result.indices {
            guard let match = inventory.match(application: result[index]) else { continue }
            matchedTokens.insert(match.package.metadata.token)
            result[index].homebrewMetadata = match.package.metadata
            result[index].caskToken = match.package.metadata.token
            result[index].sourceEvidence.append("homebrew-cli-json-v2")
            switch match.confidence {
            case .exactArtifactPath:
                result[index].sourceEvidence.append("homebrew-match:exact-artifact-path")
            case .uniqueNameFallback:
                result[index].sourceEvidence.append("homebrew-match:unique-name-fallback")
            }
        }

        for package in inventory.casks where !matchedTokens.contains(package.metadata.token) {
            result.append(syntheticApplication(for: package, inventory: inventory))
        }
        if includeFormulae {
            result.append(contentsOf: inventory.formulae.map {
                syntheticApplication(for: $0, inventory: inventory)
            })
        }
        return result
    }

    private func syntheticApplication(
        for package: HomebrewInventoryPackage,
        inventory: HomebrewInventory
    ) -> InstalledApplication {
        let metadata = package.metadata
        let installedVersion = metadata.installedVersions.last ?? ""
        let installedVersionValue = ApplicationVersion(marketing: installedVersion)
        let availableVersion = HomebrewAutomaticUpdateSafety.strictlyNewerCurrentVersion(
            metadata: metadata,
            installedVersion: installedVersionValue
        )
        let bundleURL: URL
        let packageKind: ApplicationPackageKind
        let bundleIdentifier: String
        switch metadata.kind {
        case .cask:
            bundleURL = metadata.appBundlePaths.first.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? inventory.prefixURL
                .appendingPathComponent("Caskroom", isDirectory: true)
                .appendingPathComponent(metadata.token, isDirectory: true)
            packageKind = .graphicalApplication
            bundleIdentifier = "homebrew.cask.\(metadata.token)"
        case .formula:
            bundleURL = inventory.prefixURL
                .appendingPathComponent("Cellar", isDirectory: true)
                .appendingPathComponent(metadata.token, isDirectory: true)
                .appendingPathComponent(installedVersion, isDirectory: true)
            packageKind = .commandLineTool
            bundleIdentifier = "homebrew.formula.\(metadata.token)"
        }
        return InstalledApplication(
            id: "homebrew:\(metadata.kind.rawValue):\(metadata.token)",
            displayName: package.displayNames.first ?? metadata.token,
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            executableURL: nil,
            installedVersion: installedVersionValue,
            buildNumber: "",
            signingTeamIdentifier: nil,
            codeSigningIdentifier: bundleIdentifier,
            installationSource: metadata.kind == .formula ? .homebrewFormula : .homebrewCask,
            updateProvider: .homebrew,
            architectures: [],
            minimumSystemVersion: nil,
            isSystemApplication: false,
            isRunning: false,
            isOnExternalVolume: false,
            isReadOnly: false,
            lastScanDate: Date(),
            availableVersion: availableVersion,
            updateStatus: .discovered,
            requiresUserInteraction: true,
            requiresApplicationQuit: false,
            requiresAdministratorAuthorization: false,
            canAutomaticallyUpdate: false,
            packageKind: packageKind,
            sourceDisplayName: "Homebrew",
            sourceEvidence: ["homebrew-cli-json-v2", "homebrew-package-inventory"],
            homebrewMetadata: metadata,
            caskToken: metadata.kind == .cask ? metadata.token : nil,
            reportedCurrentVersion: installedVersion.nonEmpty
        )
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter {
            seen.insert(ApplicationPathNormalizer.comparisonKey(for: $0)).inserted
        }
    }

    private func shouldInclude(_ url: URL, includeExternalVolumes: Bool) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsReadOnlyKey])
        guard values?.volumeIsInternal == false else { return true }
        return includeExternalVolumes && values?.volumeIsReadOnly != true
    }
}
