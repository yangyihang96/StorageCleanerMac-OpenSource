import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateModelsScanningProviderTests: XCTestCase {
    func testInventoryScanAwaitsCallbacksAndStopsMetadataWorkOnCancellation() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scanner = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/AppUpdates/Scanning/ApplicationInventoryScanner.swift"
            ),
            encoding: .utf8
        )
        let store = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Stores/ScanStore.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(scanner.contains("(ApplicationScanProgress) async -> Void"))
        XCTAssertTrue(scanner.contains("([InstalledApplication]) async -> Void"))
        XCTAssertTrue(scanner.contains("maximumConcurrentMetadataReads = 4"))
        XCTAssertTrue(scanner.contains("return results.sorted { $0.0 < $1.0 }"))
        XCTAssertTrue(scanner.contains("try Task.checkCancellation()"))
        XCTAssertFalse(scanner.contains("if Task.isCancelled { break }"))
        XCTAssertTrue(store.contains("await MainActor.run { [weak self] in"))
    }

    func testReadingDefaultUpdatePreferencesDoesNotPersistOrNotifyAChange() throws {
        let suiteName = "AppUpdatePreferencesReadTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let didChange = expectation(
            forNotification: UserDefaults.didChangeNotification,
            object: defaults
        )
        didChange.isInverted = true

        let preferences = ApplicationUpdatePreferences.snapshot(defaults: defaults)

        XCTAssertTrue(preferences.automaticallyChecks)
        XCTAssertEqual(preferences.checkFrequency, .weekly)
        XCTAssertTrue(preferences.alwaysCreatesPlan)
        XCTAssertTrue(preferences.updatesAfterApplicationQuits)
        XCTAssertTrue(preferences.includesHomebrewFormulae)
        XCTAssertTrue(preferences.notifiesOnCompletion)
        XCTAssertFalse(preferences.automaticallyExecutesSilentUpdates)
        wait(for: [didChange], timeout: 0.05)
        XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
    }

    func testSilentAutomaticUpdatePreferenceIsOneCoherentOptIn() {
        var preferences = ApplicationUpdatePreferencesSnapshot(
            automaticallyChecks: true,
            checkFrequency: .weekly,
            automaticallyDownloadsVerifiedUpdates: false,
            automaticallyInstallsSilentUpdates: false,
            alwaysCreatesPlan: true,
            updatesAfterApplicationQuits: true,
            includesHomebrewFormulae: true,
            checksSelfUpdatingHomebrewCasks: false,
            scansExternalVolumes: false,
            notifiesOnCompletion: true
        )

        XCTAssertFalse(preferences.automaticallyExecutesSilentUpdates)

        preferences.setAutomaticSilentUpdateExecution(true)
        XCTAssertTrue(preferences.automaticallyDownloadsVerifiedUpdates)
        XCTAssertTrue(preferences.automaticallyInstallsSilentUpdates)
        XCTAssertFalse(preferences.alwaysCreatesPlan)
        XCTAssertTrue(preferences.automaticallyExecutesSilentUpdates)

        preferences.setAutomaticSilentUpdateExecution(false)
        XCTAssertFalse(preferences.automaticallyDownloadsVerifiedUpdates)
        XCTAssertFalse(preferences.automaticallyInstallsSilentUpdates)
        XCTAssertTrue(preferences.alwaysCreatesPlan)
        XCTAssertFalse(preferences.automaticallyExecutesSilentUpdates)
    }

    func testSettingsDoNotOfferAnUnsupportedDownloadOnlyMode() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/SettingsView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("自动安装可静默更新项目"))
        XCTAssertTrue(source.contains("签名变化会阻止自动安装"))
        XCTAssertFalse(source.contains("自动下载已验证更新"))
        XCTAssertFalse(source.contains("更新前创建计划"))
    }

    func testApplicationUpdateCheckScheduleHonorsFrequencyBoundariesAndOptOuts() throws {
        let suiteName = "AppUpdateCheckScheduleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let checkedAt = Date(timeIntervalSince1970: 1_789_000_000)
        var preferences = ApplicationUpdatePreferencesSnapshot(
            automaticallyChecks: true,
            checkFrequency: .daily,
            automaticallyDownloadsVerifiedUpdates: false,
            automaticallyInstallsSilentUpdates: false,
            alwaysCreatesPlan: true,
            updatesAfterApplicationQuits: true,
            includesHomebrewFormulae: true,
            checksSelfUpdatingHomebrewCasks: false,
            scansExternalVolumes: false,
            notifiesOnCompletion: true
        )

        XCTAssertTrue(ApplicationUpdateCheckSchedule.shouldCheck(
            preferences: preferences,
            now: checkedAt,
            defaults: defaults
        ))
        ApplicationUpdateCheckSchedule.markChecked(at: checkedAt, defaults: defaults)
        XCTAssertFalse(ApplicationUpdateCheckSchedule.shouldCheck(
            preferences: preferences,
            now: checkedAt.addingTimeInterval(24 * 60 * 60 - 1),
            defaults: defaults
        ))
        XCTAssertTrue(ApplicationUpdateCheckSchedule.shouldCheck(
            preferences: preferences,
            now: checkedAt.addingTimeInterval(24 * 60 * 60),
            defaults: defaults
        ))

        preferences.checkFrequency = .weekly
        XCTAssertFalse(ApplicationUpdateCheckSchedule.shouldCheck(
            preferences: preferences,
            now: checkedAt.addingTimeInterval(7 * 24 * 60 * 60 - 1),
            defaults: defaults
        ))
        XCTAssertTrue(ApplicationUpdateCheckSchedule.shouldCheck(
            preferences: preferences,
            now: checkedAt.addingTimeInterval(7 * 24 * 60 * 60),
            defaults: defaults
        ))

        preferences.checkFrequency = .manual
        XCTAssertFalse(ApplicationUpdateCheckSchedule.shouldCheck(
            preferences: preferences,
            now: checkedAt.addingTimeInterval(30 * 24 * 60 * 60),
            defaults: defaults
        ))
        preferences.checkFrequency = .daily
        preferences.automaticallyChecks = false
        XCTAssertFalse(ApplicationUpdateCheckSchedule.shouldCheck(
            preferences: preferences,
            now: checkedAt.addingTimeInterval(30 * 24 * 60 * 60),
            defaults: defaults
        ))
    }

    func testApplicationVersionUsesNumericComponentsInsteadOfLexicalOrdering() {
        XCTAssertLessThan(
            ApplicationVersion(marketing: "1.9"),
            ApplicationVersion(marketing: "1.10")
        )
        XCTAssertLessThan(
            ApplicationVersion(marketing: "2.0-beta.9"),
            ApplicationVersion(marketing: "2.0-beta.10")
        )
        XCTAssertEqual(ApplicationVersion.compare("3.0", "3.0.0"), .orderedSame)
    }

    func testLegacyAppStoreItemIsNeverOneClickAutomatic() {
        let application = InstalledApplication(
            id: "store",
            name: "Store App",
            bundleIdentifier: "com.example.store",
            path: "/Applications/Store App.app",
            version: "1.0",
            build: "100",
            source: "App Store",
            method: .appStore,
            feedURL: nil,
            caskToken: nil,
            currentVersion: "1.0",
            latestVersion: "1.1",
            modifiedAt: nil
        )

        XCTAssertFalse(application.canRunInOneClickUpdate)
        XCTAssertEqual(application.updateProvider, .macAppStore)
        XCTAssertTrue(application.requiresUserInteraction)
    }

    func testPathDeduplicationKeepsRicherMetadata() {
        let sparse = AppUpdateTestFixtures.application(
            id: "sparse",
            name: "Sparse",
            bundleIdentifier: "",
            path: "/Applications/Example.app",
            version: "",
            signingTeamIdentifier: nil,
            codeSigningIdentifier: nil,
            lastScanDate: Date(timeIntervalSince1970: 200)
        )
        let rich = AppUpdateTestFixtures.application(
            id: "rich",
            path: "/applications/EXAMPLE.app",
            lastScanDate: Date(timeIntervalSince1970: 100)
        )

        let result = ApplicationDeduplicator().deduplicatePaths([sparse, rich])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "rich")
    }

    func testDuplicateBundleCopiesRemainSeparateAndListEveryLocation() {
        let primary = AppUpdateTestFixtures.application(
            id: "primary",
            path: "/Applications/Example.app"
        )
        let copy = AppUpdateTestFixtures.application(
            id: "copy",
            path: "/Users/test/Applications/Example.app"
        )

        let result = ApplicationDeduplicator().process([primary, copy])

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy(\.isDuplicate))
        XCTAssertTrue(result.allSatisfy { $0.duplicateLocations.count == 2 })
        XCTAssertEqual(Set(result.flatMap(\.duplicateLocations).map(\.path)).count, 2)
    }

    func testDuplicateCopyGroupMatchesAnyCopyWithoutAllowingAutomaticUpdate() throws {
        let bundleIdentifier = "com.example.copies"
        var websiteCopy = AppUpdateTestFixtures.application(
            id: "website",
            name: "Website Copy",
            bundleIdentifier: bundleIdentifier,
            path: "/Volumes/Apps/WebsiteExample.app",
            provider: .officialWebsite,
            status: .upToDate
        )
        websiteCopy.officialSource = OfficialUpdateSource(
            applicationIdentity: websiteCopy.identity,
            providerType: .officialWebsite,
            developerName: "Example",
            homepageURL: URL(string: "https://example.com"),
            updatePageURL: URL(string: "https://example.com/update"),
            releaseFeedURL: nil,
            directDownloadURL: nil,
            allowedHosts: ["example.com"],
            expectedBundleIdentifier: bundleIdentifier,
            expectedTeamIdentifier: websiteCopy.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .userConfirmation,
            trustLevel: .userConfirmed,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: .manualWebsite,
            expectedPackageExtensions: [],
            officialGitHubRepository: nil
        )
        let copies = [
            AppUpdateTestFixtures.application(
                id: "manual",
                name: "Manual Copy",
                bundleIdentifier: bundleIdentifier,
                path: "/Applications/Example.app",
                provider: .manual,
                status: .sourceUnconfirmed
            ),
            AppUpdateTestFixtures.application(
                id: "store",
                name: "Store Copy",
                bundleIdentifier: bundleIdentifier,
                path: "/Users/test/Applications/StoreExample.app",
                availableVersion: "2.0",
                provider: .macAppStore,
                status: .updateAvailable
            ),
            websiteCopy,
            AppUpdateTestFixtures.application(
                id: "sparkle",
                name: "In-App Copy",
                bundleIdentifier: bundleIdentifier,
                path: "/Users/test/Desktop/InAppExample.app",
                provider: .sparkle,
                status: .failed
            ),
            AppUpdateTestFixtures.strictHomebrewApplication(
                id: "automatic",
                token: "automatic-copy",
                path: "/Users/test/Downloads/AutomaticExample.app"
            ),
        ].map { application -> InstalledApplication in
            var copy = application
            copy.bundleIdentifier = bundleIdentifier
            return copy
        }
        let group = try XCTUnwrap(AppUpdateApplicationCopyGroup.make(from: copies).first)

        XCTAssertTrue(group.matches(.appStore, query: "Store Copy"))
        XCTAssertTrue(group.matches(.websiteDownload))
        XCTAssertTrue(group.matches(.websiteManual))
        XCTAssertTrue(group.matches(.applicationInternal))
        XCTAssertTrue(group.matches(.updateAvailable))
        XCTAssertTrue(group.matches(.upToDate))
        XCTAssertTrue(group.matches(.failed))
        XCTAssertTrue(group.matches(.sourceUnconfirmed))
        XCTAssertFalse(group.matches(.automatic))
        XCTAssertTrue(group.containsThirdParty { $0.effectiveVersionCheckState == .upToDate })
    }

    func testDuplicateCopyCannotJoinAutomaticPlanFromDetailView() {
        let eligible = AppUpdateTestFixtures.strictHomebrewApplication(id: "eligible")
        var duplicate = eligible
        duplicate.isDuplicate = true
        duplicate.duplicateLocations = [
            duplicate.bundleURL,
            URL(fileURLWithPath: "/Users/test/Applications/Example.app")
        ]

        XCTAssertTrue(eligible.canJoinAutomaticUpdatePlan)
        XCTAssertFalse(duplicate.canJoinAutomaticUpdatePlan)
    }

    func testDuplicateCopyGroupFilterCountCountsEachBundleOnce() {
        let firstCopy = AppUpdateTestFixtures.application(
            id: "first-copy",
            bundleIdentifier: "com.example.copies",
            path: "/Applications/Example.app",
            provider: .manual
        )
        let secondCopy = AppUpdateTestFixtures.application(
            id: "second-copy",
            bundleIdentifier: "com.example.copies",
            path: "/Users/test/Applications/Example.app",
            provider: .macAppStore
        )
        let thirdCopy = AppUpdateTestFixtures.application(
            id: "third-copy",
            bundleIdentifier: "com.example.copies",
            path: "/Users/test/Desktop/Example.app",
            provider: .macAppStore
        )
        let otherApplication = AppUpdateTestFixtures.application(
            id: "other",
            bundleIdentifier: "com.example.other",
            path: "/Applications/Other.app",
            provider: .macAppStore
        )

        XCTAssertEqual(
            AppUpdateApplicationCopyGroup.count(
                in: [firstCopy, secondCopy, thirdCopy, otherApplication],
                matching: .appStore
            ),
            2
        )
    }

    func testHomebrewJSONParsesFormulaAndCaskSafetyMetadata() throws {
        let installed = Data(
            #"""
            {
              "formulae": [{
                "name": "wget",
                "full_name": "wget",
                "homepage": "https://www.gnu.org/software/wget/",
                "installed": [{"version": "1.24.0"}],
                "versions": {"stable": "1.25.0"},
                "pinned": true,
                "disabled": false,
                "deprecated": false
              }],
              "casks": [{
                "token": "example",
                "name": ["Example App"],
                "homepage": "https://example.com",
                "installed": "1.0,0123456abcdef",
                "version": "2.0,abcdef0123456",
                "auto_updates": false,
                "artifacts": [{"app": ["Example.app", {"target": "Example.app"}]}]
              }]
            }
            """#.utf8
        )
        // Homebrew's v2 output uses `name` for an outdated cask, even though
        // installed cask metadata uses `token`.
        let outdated = Data(
            #"{"formulae":[{"name":"wget"}],"casks":[{"name":"example"}]}"#.utf8
        )

        let packages = try HomebrewInventoryParser.parse(
            installedData: installed,
            outdatedData: outdated,
            prefixURL: URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)
        )

        let formula = try XCTUnwrap(packages.first { $0.metadata.kind == .formula })
        XCTAssertEqual(formula.metadata.token, "wget")
        XCTAssertEqual(formula.metadata.currentVersion, "1.25.0")
        XCTAssertTrue(formula.metadata.isOutdated)
        XCTAssertTrue(formula.metadata.isPinned)

        let cask = try XCTUnwrap(packages.first { $0.metadata.kind == .cask })
        XCTAssertEqual(cask.metadata.token, "example")
        XCTAssertEqual(cask.metadata.installedVersions, ["1.0,0123456abcdef"])
        XCTAssertEqual(cask.metadata.currentVersion, "2.0,abcdef0123456")
        XCTAssertEqual(cask.metadata.appBundlePaths, ["/Applications/Example.app"])
        XCTAssertTrue(cask.metadata.isOutdated)
        XCTAssertFalse(cask.metadata.requiresManualInstaller)
        XCTAssertEqual(cask.metadata.effectiveOutdatedProvenance, .plain)
    }

    func testHomebrewJSONPreservesDistinctCSVVersionTuples() throws {
        let installed = Data(
            #"""
            {
              "formulae": [],
              "casks": [
                {
                  "token": "build-100",
                  "installed": ["1.2.3,100"],
                  "version": "1.2.3,100",
                  "artifacts": []
                },
                {
                  "token": "build-200",
                  "installed": ["1.2.3,200"],
                  "version": "1.2.3,200",
                  "artifacts": []
                },
                {
                  "token": "empty-prefix",
                  "installed": [",100"],
                  "version": ",200",
                  "artifacts": []
                },
                {
                  "token": "multi-csv",
                  "installed": ["1.2.3,100,arm64"],
                  "version": "1.2.3,200,arm64",
                  "artifacts": []
                }
              ]
            }
            """#.utf8
        )

        let packages = try HomebrewInventoryParser.parse(
            installedData: installed,
            outdatedData: nil,
            prefixURL: URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)
        )

        let metadata = Dictionary(
            uniqueKeysWithValues: packages.map { ($0.metadata.token, $0.metadata) }
        )
        XCTAssertEqual(metadata["build-100"]?.currentVersion, "1.2.3,100")
        XCTAssertEqual(metadata["build-200"]?.currentVersion, "1.2.3,200")
        XCTAssertEqual(metadata["build-100"]?.installedVersions, ["1.2.3,100"])
        XCTAssertEqual(metadata["build-200"]?.installedVersions, ["1.2.3,200"])
        XCTAssertEqual(metadata["empty-prefix"]?.currentVersion, ",200")
        XCTAssertEqual(metadata["multi-csv"]?.currentVersion, "1.2.3,200,arm64")
    }

    func testHomebrewCaskOutdatedProvenanceIgnoresInstalledInfoFlagAndFailsClosed() async throws {
        let installed = Data(
            #"""
            {
              "formulae": [],
              "casks": [{
                "token": "example",
                "name": ["Example App"],
                "installed": ["1.0,0123456abcdef"],
                "version": "2.0,abcdef0123456",
                "outdated": true,
                "auto_updates": true,
                "artifacts": [{"app": ["Example.app", {"target": "Example.app"}]}]
              }]
            }
            """#.utf8
        )
        let plainMatch = Data(
            #"{"formulae":[],"casks":[{"name":"example"}]}"#.utf8
        )
        let plainEmpty = Data(#"{"formulae":[],"casks":[]}"#.utf8)
        let greedyMatch = Data(
            #"{"formulae":[],"casks":[{"token":"example"}]}"#.utf8
        )
        let cases: [(
            name: String,
            plain: Data?,
            greedy: Data?,
            isOutdated: Bool,
            provenance: HomebrewOutdatedProvenance,
            expectsParserError: Bool
        )] = [
            ("plain-wins", plainMatch, greedyMatch, true, .plain, false),
            ("greedy-only", plainEmpty, greedyMatch, true, .greedy, false),
            ("plain-failed-greedy-only", nil, greedyMatch, true, .greedy, false),
            ("plain-valid-empty", plainEmpty, nil, false, .plain, false),
            ("plain-failed", nil, nil, false, .unknown, false),
            ("plain-invalid", Data("not-json".utf8), nil, false, .unknown, true),
            ("plain-empty-output", Data(), nil, false, .unknown, true),
        ]
        let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let provider = HomebrewProvider(homebrewExecutableProvider: { executableURL })

        for testCase in cases {
            if testCase.expectsParserError {
                XCTAssertThrowsError(
                    try HomebrewInventoryParser.parse(
                        installedData: installed,
                        outdatedData: testCase.plain,
                        greedyOutdatedData: testCase.greedy,
                        prefixURL: URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)
                    ),
                    testCase.name
                )
                continue
            }
            let packages = try HomebrewInventoryParser.parse(
                installedData: installed,
                outdatedData: testCase.plain,
                greedyOutdatedData: testCase.greedy,
                prefixURL: URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)
            )
            let cask = try XCTUnwrap(packages.first?.metadata, testCase.name)
            XCTAssertEqual(cask.isOutdated, testCase.isOutdated, testCase.name)
            XCTAssertEqual(
                cask.effectiveOutdatedProvenance,
                testCase.provenance,
                testCase.name
            )

            var application = AppUpdateTestFixtures.application(
                id: "parser-\(testCase.name)",
                path: "/Applications/Example.app",
                availableVersion: "2.0",
                provider: .homebrew,
                status: .updateAvailable,
                sourceEvidence: [
                    "homebrew-cli-json-v2",
                    "homebrew-match:exact-artifact-path",
                    "valid-code-signature",
                ],
                homebrewMetadata: cask,
                canAutomaticallyUpdate: true,
                requiresUserInteraction: false
            )
            let source = try await provider.inspect(application)
            let check = try await provider.checkForUpdate(application)
            application.availableVersion = check.availableVersion
            application.updateStatus = check.status
            application.updateCapability = source.canAutomaticallyUpdate ? .automatic : .manual
            application.canAutomaticallyUpdate = source.canAutomaticallyUpdate
            application.requiresUserInteraction = source.requiresUserInteraction
            let shouldBeAutomatic = testCase.provenance == .plain && testCase.isOutdated

            XCTAssertEqual(source.canAutomaticallyUpdate, shouldBeAutomatic, testCase.name)
            XCTAssertEqual(
                ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(application),
                shouldBeAutomatic,
                testCase.name
            )
            XCTAssertEqual(
                HomebrewUpdateRecipeBuilder.make(
                    application: application,
                    executableURL: executableURL,
                    environment: [
                        "HOME": "/Users/example",
                        "TMPDIR": "/private/tmp/example",
                    ]
                ) != nil,
                shouldBeAutomatic,
                testCase.name
            )
        }
    }

    func testHomebrewParserFailsClosedWhenInstalledRootIsMalformedOrPackageListsAreInvalid() {
        let malformedRoots = [
            Data("not-json".utf8),
            Data(#"{}"#.utf8),
            Data(#"{"formulae":[]}"#.utf8),
            Data(#"{"casks":[]}"#.utf8),
            Data(#"{"formulae":{},"casks":[]}"#.utf8),
            Data(#"{"formulae":[],"casks":{}}"#.utf8),
        ]

        for malformedInstalled in malformedRoots {
            XCTAssertThrowsError(
                try HomebrewInventoryParser.parse(
                    installedData: malformedInstalled,
                    outdatedData: nil,
                    prefixURL: URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)
                )
            ) { error in
                guard let scanningError = error as? ApplicationScanningError,
                      case let .invalidHomebrewOutput(detail) = scanningError else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertTrue(
                    detail == "installed JSON root" || detail == "installed JSON package lists",
                    "unexpected detail: \(detail)"
                )
            }
        }
    }

    func testHomebrewFormulaVersionParserRequiresFormulaeAndValidatesOptionalCasks() throws {
        XCTAssertNil(try HomebrewInventoryParser.installedFormulaVersion(
            from: Data(#"{"formulae":[]}"#.utf8),
            expectedToken: "example"
        ))
        let malformedRoots = [
            Data("not-json".utf8),
            Data(#"{}"#.utf8),
            Data(#"{"casks":[]}"#.utf8),
            Data(#"{"formulae":{},"casks":[]}"#.utf8),
            Data(#"{"formulae":[],"casks":{}}"#.utf8),
        ]

        for malformed in malformedRoots {
            XCTAssertThrowsError(
                try HomebrewInventoryParser.installedFormulaVersion(
                    from: malformed,
                    expectedToken: "example"
                )
            ) { error in
                guard let scanningError = error as? ApplicationScanningError,
                      case let .invalidHomebrewOutput(detail) = scanningError else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertTrue(
                    detail == "formula info JSON root"
                        || detail == "formula info JSON package lists",
                    "unexpected detail: \(detail)"
                )
            }
        }
    }

    func testHomebrewParserFailsClosedWhenOutdatedPackageListsAreWrongType() {
        let installed = Data(#"{"formulae":[],"casks":[]}"#.utf8)
        let malformedOutdated = Data(#"{"formulae":{},"casks":[]}"#.utf8)
        XCTAssertThrowsError(
            try HomebrewInventoryParser.parse(
                installedData: installed,
                outdatedData: malformedOutdated,
                prefixURL: URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)
            )
        )
    }

    func testLegacyHomebrewMetadataWithoutProvenanceDecodesAsUnknown() throws {
        let encoded = try JSONEncoder().encode(AppUpdateTestFixtures.homebrewMetadata())
        var dictionary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        dictionary.removeValue(forKey: "outdatedProvenance")
        let legacy = try JSONSerialization.data(withJSONObject: dictionary)

        let decoded = try JSONDecoder().decode(HomebrewPackageMetadata.self, from: legacy)

        XCTAssertTrue(decoded.isOutdated)
        XCTAssertEqual(decoded.effectiveOutdatedProvenance, .unknown)
        XCTAssertFalse(decoded.hasPlainOutdatedEvidence)
    }

    func testFormulaVersionVerificationUsesOneTokenScopedBrewInfoCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormulaVersionQuery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let brew = bin.appendingPathComponent("brew", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: brew.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: brew.path
        )
        let response = Data(#"""
        {
          "formulae": [{
            "name": "example",
            "full_name": "example",
            "installed": [{"version": "2.0"}]
          }],
          "casks": []
        }
        """#.utf8)
        let runner = RecordingHomebrewCommandRunner(response: response)
        let scanner = HomebrewInventoryScanner(runner: runner)

        let version = try await scanner.installedFormulaVersion(
            token: "example",
            environment: [
                "HOMEBREW_PREFIX": root.path,
                "HOMEBREW_BREW_FILE": brew.path,
            ]
        )

        XCTAssertEqual(version, ApplicationVersion(marketing: "2.0"))
        let invocations = await runner.recordedInvocations()
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.executableURL, brew.standardizedFileURL)
        XCTAssertEqual(
            invocations.first?.arguments,
            ["info", "--json=v2", "--formula", "example"]
        )
        XCTAssertFalse(invocations.first?.arguments.contains("--installed") ?? true)
        XCTAssertFalse(invocations.first?.arguments.contains("outdated") ?? true)
        XCTAssertEqual(invocations.first?.environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
        XCTAssertEqual(invocations.first?.environment["HOMEBREW_NO_ANALYTICS"], "1")
        XCTAssertEqual(invocations.first?.environment["NONINTERACTIVE"], "1")
        XCTAssertNil(invocations.first?.environment["HOMEBREW_PREFIX"])
        XCTAssertNil(invocations.first?.environment["HOMEBREW_BREW_FILE"])
    }

    func testFormulaVersionVerificationRejectsOptionLikeTokenBeforeRunningBrew() async {
        let runner = RecordingHomebrewCommandRunner(response: Data())
        let scanner = HomebrewInventoryScanner(runner: runner)

        do {
            _ = try await scanner.installedFormulaVersion(token: "--all")
            XCTFail("Expected option-like token to be rejected")
        } catch {
            // Expected: no Process invocation occurs for an unsafe token.
        }

        let invocations = await runner.recordedInvocations()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testHomebrewPackageTokenPolicyRejectsUnsafeFormulaAndCaskTokens() {
        XCTAssertTrue(HomebrewPackageTokenPolicy.isValid("example"))
        XCTAssertTrue(HomebrewPackageTokenPolicy.isValid("owner/tap/example@2"))
        for token in ["", " ", "-option", "name;command", "name\ncommand", "owner//name", "../name", "café"] {
            XCTAssertFalse(HomebrewPackageTokenPolicy.isValid(token), token)
        }
    }

    func testHomebrewInventoryScannerDefaultsToNonGreedyOutdatedQuery() async throws {
        let runner = ScriptedHomebrewCommandRunner()
        let scanner = HomebrewInventoryScanner(
            runner: runner,
            environmentProvider: {
                [
                    "HOME": "/Users/example",
                    "TMPDIR": "/private/tmp/example",
                    "LANG": "en_AU.UTF-8",
                    "UNSAFE_EXTRA": "must-not-pass",
                ]
            }
        )
        guard scanner.locateHomebrewExecutable() != nil else {
            throw XCTSkip("A trusted local Homebrew executable is required for this command-shape test.")
        }

        _ = try await scanner.scan()
        let invocations = await runner.invocations
        let outdated = try XCTUnwrap(invocations.first { $0.arguments.first == "outdated" })
        XCTAssertEqual(outdated.arguments, ["outdated", "--json=v2"])
        XCTAssertFalse(outdated.arguments.contains("--greedy"))
        XCTAssertFalse(invocations.isEmpty)
        XCTAssertTrue(invocations.allSatisfy {
            Set($0.environment.keys).isSubset(of: HomebrewCommandEnvironment.allowedKeys)
                && $0.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1"
                && $0.environment["HOMEBREW_NO_ANALYTICS"] == "1"
                && $0.environment["NONINTERACTIVE"] == "1"
                && $0.environment["UNSAFE_EXTRA"] == nil
        })
    }

    func testHomebrewInventoryScannerKeepsPlainAndGreedyQueriesSeparate() async throws {
        let runner = ScriptedHomebrewCommandRunner()
        let scanner = HomebrewInventoryScanner(runner: runner)
        guard scanner.locateHomebrewExecutable() != nil else {
            throw XCTSkip("A trusted local Homebrew executable is required for this command-shape test.")
        }

        _ = try await scanner.scan(includeGreedyCasks: true)
        let outdatedInvocations = await runner.invocations
            .filter { $0.arguments.first == "outdated" }

        XCTAssertEqual(outdatedInvocations.map(\.arguments), [
            ["outdated", "--json=v2"],
            ["outdated", "--json=v2", "--greedy"],
        ])
    }

    func testHomebrewAutomaticLayersRequirePlainOutdatedProvenance() async throws {
        let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let provider = HomebrewProvider(homebrewExecutableProvider: { executableURL })

        for provenance: HomebrewOutdatedProvenance in [.plain, .greedy, .unknown] {
            var application = AppUpdateTestFixtures.strictHomebrewApplication(
                id: "provenance-\(provenance.rawValue)"
            )
            application.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(
                outdatedProvenance: provenance
            )
            let shouldBeAutomatic = provenance == .plain

            let source = try await provider.inspect(application)
            let check = try await provider.checkForUpdate(application)
            XCTAssertEqual(source.canAutomaticallyUpdate, shouldBeAutomatic, provenance.rawValue)
            XCTAssertEqual(
                check.status,
                shouldBeAutomatic ? .automaticallyUpdatable : .updateAvailable,
                provenance.rawValue
            )

            // Attempt to bypass the downstream layers with stale automatic flags.
            application.updateCapability = .automatic
            application.canAutomaticallyUpdate = true
            application.requiresUserInteraction = false
            application.updateStatus = .automaticallyUpdatable
            XCTAssertEqual(
                ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(application),
                shouldBeAutomatic,
                provenance.rawValue
            )
            XCTAssertEqual(
                HomebrewUpdateRecipeBuilder.make(
                    application: application,
                    executableURL: executableURL,
                    environment: [
                        "HOME": "/Users/example",
                        "TMPDIR": "/private/tmp/example",
                    ]
                ) != nil,
                shouldBeAutomatic,
                provenance.rawValue
            )
        }
    }

    func testHomebrewCaskVersionProjectionKeepsAmbiguousCSVManual() async throws {
        let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let provider = HomebrewProvider(homebrewExecutableProvider: { executableURL })
        let cases: [(
            name: String,
            disk: String,
            installed: String,
            current: String,
            automatic: Bool,
            status: ApplicationUpdateStatus,
            available: String?
        )] = [
            ("plain", "1.0", "1.0", "2.0", true, .automaticallyUpdatable, "2.0"),
            ("digest", "1.0", "1.0,0123456abcdef", "2.0,abcdef0123456", true, .automaticallyUpdatable, "2.0"),
            ("numeric-build", "1.2.3", "1.2.3,100", "1.2.3,200", false, .updateAvailable, "1.2.3,200"),
            ("multi-csv", "1.0", "1.0,100,arm64", "2.0,200,arm64", false, .updateAvailable, "2.0,200,arm64"),
            ("empty-first", "1.0", "1.0", ",abcdef0", false, .latestVersionUnknown, nil),
            ("current-latest", "1.0", "1.0", "latest", false, .latestVersionUnknown, nil),
            ("current-colon-latest", "1.0", "1.0", ":latest", false, .latestVersionUnknown, nil),
            ("current-uppercase-latest", "1.0", "1.0", "LATEST", false, .latestVersionUnknown, nil),
            ("current-uppercase-colon-latest", "1.0", "1.0", ":LATEST", false, .latestVersionUnknown, nil),
            ("current-trimmed-colon-latest", "1.0", "1.0", "  :LaTeSt  ", false, .latestVersionUnknown, nil),
            ("installed-latest", "latest", "latest", "2.0", false, .latestVersionUnknown, nil),
            ("installed-colon-latest", ":latest", ":latest", "2.0", false, .latestVersionUnknown, nil),
            ("installed-uppercase-latest", "1.0", "LATEST", "2.0", false, .latestVersionUnknown, nil),
            ("installed-uppercase-colon-latest", "1.0", ":LATEST", "2.0", false, .latestVersionUnknown, nil),
            ("disk-uppercase-latest", "LATEST", "1.0", "2.0", false, .latestVersionUnknown, nil),
            ("disk-uppercase-colon-latest", ":LATEST", "1.0", "2.0", false, .latestVersionUnknown, nil),
            ("short-digest", "1.0", "1.0,abc123", "2.0,def456", false, .updateAvailable, "2.0,def456"),
            ("numeric-digest-tail", "1.0", "1.0,1234567", "2.0,2345678", false, .updateAvailable, "2.0,2345678"),
        ]

        for testCase in cases {
            var application = AppUpdateTestFixtures.application(
                id: "version-\(testCase.name)",
                version: testCase.disk,
                provider: .homebrew,
                status: .updateAvailable,
                sourceEvidence: ["homebrew-match:exact-artifact-path", "valid-code-signature"],
                homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(
                    installedVersions: [testCase.installed],
                    currentVersion: testCase.current,
                    autoUpdates: true
                ),
                requiresUserInteraction: false
            )
            let source = try await provider.inspect(application)
            let check = try await provider.checkForUpdate(application)

            XCTAssertEqual(source.canAutomaticallyUpdate, testCase.automatic, testCase.name)
            XCTAssertEqual(check.status, testCase.status, testCase.name)
            XCTAssertEqual(check.availableVersion?.marketing, testCase.available, testCase.name)

            application.availableVersion = check.availableVersion
            application.versionCheckState = check.availableVersion == nil
                ? .unavailable
                : .updateAvailable
            application.updateCapability = .automatic
            application.canAutomaticallyUpdate = true
            application.requiresUserInteraction = false
            application.updateStatus = .automaticallyUpdatable
            XCTAssertEqual(
                ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(application),
                testCase.automatic,
                testCase.name
            )
            XCTAssertEqual(
                HomebrewUpdateRecipeBuilder.make(
                    application: application,
                    executableURL: executableURL,
                    environment: ["HOME": "/Users/example", "TMPDIR": "/private/tmp/example"]
                ) != nil,
                testCase.automatic,
                testCase.name
            )
        }
    }

    func testHomebrewAutoUpdatesCaskRequiresStrictComparableTargetAndIdentity() async throws {
        let provider = HomebrewProvider(
            homebrewExecutableProvider: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }
        )
        let cases: [(name: String, current: String?, outdated: Bool, expectedAutomatic: Bool)] = [
            ("newer", "2.0", true, true),
            ("not-outdated", "2.0", false, false),
            ("equal", "1.0", true, false),
            ("lower", "0.9", true, false),
            ("latest", ":latest", true, false),
        ]

        for testCase in cases {
            let application = AppUpdateTestFixtures.application(
                id: "homebrew-\(testCase.name)",
                availableVersion: "2.0",
                provider: .homebrew,
                status: .updateAvailable,
                sourceEvidence: ["homebrew-match:exact-artifact-path", "valid-code-signature"],
                homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(
                    currentVersion: testCase.current,
                    isOutdated: testCase.outdated,
                    autoUpdates: true
                ),
                canAutomaticallyUpdate: false,
                requiresUserInteraction: false
            )
            let source = try await provider.inspect(application)
            XCTAssertEqual(source.canAutomaticallyUpdate, testCase.expectedAutomatic, testCase.name)
            let check = try await provider.checkForUpdate(application)
            if testCase.name == "not-outdated" {
                XCTAssertEqual(check.status, .upToDate)
            } else if testCase.expectedAutomatic {
                XCTAssertEqual(check.status, .automaticallyUpdatable)
                XCTAssertEqual(check.availableVersion, ApplicationVersion(marketing: "2.0"))
                var planned = application
                planned.updateCapability = .automatic
                planned.canAutomaticallyUpdate = true
                planned.updateStatus = .automaticallyUpdatable
                let plan = ApplicationUpdatePlanBuilder().build(applications: [planned])
                XCTAssertEqual(plan.automaticApplicationIDs, [planned.id])
            } else {
                if testCase.current == ":latest" || testCase.current == "latest" {
                    XCTAssertEqual(check.status, .latestVersionUnknown)
                    XCTAssertNil(check.availableVersion)
                } else {
                    XCTAssertEqual(check.status, .updateAvailable)
                    XCTAssertEqual(check.availableVersion?.marketing, testCase.current)
                }
                var planned = application
                planned.updateCapability = .automatic
                planned.canAutomaticallyUpdate = true
                planned.updateStatus = .automaticallyUpdatable
                let plan = ApplicationUpdatePlanBuilder().build(applications: [planned])
                XCTAssertTrue(plan.automaticApplicationIDs.isEmpty, testCase.name)
            }
        }

        let incompleteIdentity = AppUpdateTestFixtures.application(
            id: "homebrew-incomplete-identity",
            availableVersion: "2.0",
            signingTeamIdentifier: nil,
            provider: .homebrew,
            status: .updateAvailable,
            sourceEvidence: ["homebrew-match:exact-artifact-path", "valid-code-signature"],
            homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(autoUpdates: true),
            requiresUserInteraction: false
        )
        let incompleteInfo = try await provider.inspect(incompleteIdentity)
        XCTAssertFalse(incompleteInfo.canAutomaticallyUpdate)

        let ambiguousPath = AppUpdateTestFixtures.application(
            id: "homebrew-ambiguous-path",
            availableVersion: "2.0",
            provider: .homebrew,
            status: .updateAvailable,
            sourceEvidence: ["homebrew-match:unique-name-fallback", "valid-code-signature"],
            homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(autoUpdates: true),
            requiresUserInteraction: false
        )
        let ambiguousInfo = try await provider.inspect(ambiguousPath)
        XCTAssertFalse(ambiguousInfo.canAutomaticallyUpdate)
    }

    func testHomebrewAutomaticVersionGateRejectsSymbolicInstalledLatest() async throws {
        let provider = HomebrewProvider(
            homebrewExecutableProvider: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }
        )
        let cases: [(
            name: String,
            diskVersion: String,
            metadataInstalled: [String],
            expectedStatus: ApplicationUpdateStatus,
            expectedAvailable: String?
        )] = [
            ("latest", "latest", ["latest"], .latestVersionUnknown, nil),
            ("colon-latest", ":latest", [":latest"], .latestVersionUnknown, nil),
            ("uppercase-latest", "LATEST", ["LATEST"], .latestVersionUnknown, nil),
            ("uppercase-colon-latest", ":LATEST", [":LATEST"], .latestVersionUnknown, nil),
            ("mixed-latest", "1.0", ["1.0", "latest"], .latestVersionUnknown, nil),
            ("mixed-colon-latest", "1.0", ["1.0", ":LATEST"], .latestVersionUnknown, nil),
        ]

        for testCase in cases {
            let application = AppUpdateTestFixtures.application(
                id: "homebrew-symbolic-installed-(testCase.name)",
                version: testCase.diskVersion,
                availableVersion: "2.0",
                provider: .homebrew,
                status: .updateAvailable,
                sourceEvidence: ["homebrew-match:exact-artifact-path", "valid-code-signature"],
                homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(
                    installedVersions: testCase.metadataInstalled,
                    currentVersion: "2.0",
                    autoUpdates: true
                ),
                requiresUserInteraction: false
            )

            let source = try await provider.inspect(application)
            let check = try await provider.checkForUpdate(application)

            XCTAssertFalse(source.canAutomaticallyUpdate, testCase.name)
            XCTAssertEqual(check.status, testCase.expectedStatus, testCase.name)
            XCTAssertEqual(check.availableVersion?.marketing, testCase.expectedAvailable, testCase.name)
        }
    }

    func testHomebrewExactArtifactPathWinsAndNameFallbackIsExplicit() throws {
        let package = HomebrewInventoryPackage(
            metadata: AppUpdateTestFixtures.homebrewMetadata(),
            displayNames: ["Example App"],
            exactApplicationPaths: [
                ApplicationPathNormalizer.comparisonKey(
                    for: URL(fileURLWithPath: "/Applications/Example.app")
                )
            ]
        )
        let inventory = HomebrewInventory(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            prefixURL: URL(fileURLWithPath: "/opt/homebrew"),
            packages: [package]
        )

        let exact = try XCTUnwrap(inventory.match(application: AppUpdateTestFixtures.application()))
        XCTAssertEqual(exact.confidence, .exactArtifactPath)

        let moved = AppUpdateTestFixtures.application(path: "/Users/test/Example App.app")
        let fallback = try XCTUnwrap(inventory.match(application: moved))
        XCTAssertEqual(fallback.confidence, .uniqueNameFallback)
    }

    func testHomebrewAmbiguousNameFallbackDoesNotGuess() {
        let first = HomebrewInventoryPackage(
            metadata: AppUpdateTestFixtures.homebrewMetadata(token: "example-one"),
            displayNames: ["Example"],
            exactApplicationPaths: []
        )
        let second = HomebrewInventoryPackage(
            metadata: AppUpdateTestFixtures.homebrewMetadata(token: "example-two"),
            displayNames: ["Example"],
            exactApplicationPaths: []
        )
        let inventory = HomebrewInventory(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            prefixURL: URL(fileURLWithPath: "/opt/homebrew"),
            packages: [first, second]
        )

        XCTAssertNil(inventory.match(application: AppUpdateTestFixtures.application()))
    }

    func testHomebrewExecutableTrustRejectsTemporaryAndWorldWritablePrefixes() throws {
        XCTAssertFalse(HomebrewExecutableTrustPolicy.isSafeDeclaredPrefix(
            URL(fileURLWithPath: "/private/tmp/untrusted-homebrew", isDirectory: true)
        ))
        XCTAssertFalse(HomebrewExecutableTrustPolicy.isSafeDeclaredPrefix(
            URL(fileURLWithPath: "/tmp/untrusted-homebrew", isDirectory: true)
        ))
        XCTAssertTrue(HomebrewExecutableTrustPolicy.isSafeDeclaredPrefix(
            URL(fileURLWithPath: "/Users/example/.homebrew", isDirectory: true)
        ))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("untrusted-homebrew-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let brew = bin.appendingPathComponent("brew", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: brew.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: brew.path)

        XCTAssertFalse(HomebrewExecutableTrustPolicy.isTrusted(
            brew,
            declaredPrefix: root
        ))
    }

    func testHomebrewScannerRejectsMismatchedEnvironmentExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("homebrew-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("trusted", isDirectory: true)
        let bin = prefix.appendingPathComponent("bin", isDirectory: true)
        let brew = bin.appendingPathComponent("brew", isDirectory: false)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: brew.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)

        let scanner = HomebrewInventoryScanner()
        let resolved = scanner.locateHomebrewExecutable(environment: [
            "HOMEBREW_PREFIX": prefix.path,
            "HOMEBREW_BREW_FILE": root.appendingPathComponent("other/bin/brew").path,
        ])

        XCTAssertNotEqual(resolved?.standardizedFileURL, brew.standardizedFileURL)
    }

    func testProviderPriorityIsSystemAppStoreHomebrewSparkleOfficialManual() async {
        let registry = ApplicationUpdateProviderRegistry(providers: [
            SystemManagedProvider(),
            MacAppStoreProvider(receiptVerifier: FixedMacAppStoreReceiptVerifier(result: true)),
            HomebrewProvider(),
            SparkleProvider(),
            OfficialWebsiteUpdateProvider(),
            ManualUpdateProvider(),
        ])
        var application = AppUpdateTestFixtures.application(
            sourceEvidence: [
                "app-store-receipt",
                "verified-app-store-receipt",
                "valid-code-signature",
                "signed-bundle-identity",
                "app-sandbox-entitlement",
                "sparkle-feed",
            ],
            homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(),
            isSystem: true
        )
        var identifier = await registry.provider(for: application).identifier
        XCTAssertEqual(identifier, .systemManaged)

        application.isSystemApplication = false
        identifier = await registry.provider(for: application).identifier
        XCTAssertEqual(identifier, .macAppStore)

        application.sourceEvidence.removeAll {
            $0 == "app-store-receipt"
                || $0 == "verified-app-store-receipt"
                || $0 == "signed-bundle-identity"
        }
        identifier = await registry.provider(for: application).identifier
        XCTAssertEqual(identifier, .homebrew)

        application.homebrewMetadata = nil
        identifier = await registry.provider(for: application).identifier
        XCTAssertEqual(identifier, .sparkle)

        application.sourceEvidence = []
        application.feedURL = nil
        application.officialSource = officialSource(for: application)
        identifier = await registry.provider(for: application).identifier
        XCTAssertEqual(identifier, .officialWebsite)

        application.officialSource = nil
        identifier = await registry.provider(for: application).identifier
        XCTAssertEqual(identifier, .manual)
    }

    func testProviderArbitrationKeepsStrictAutomaticHomebrewAheadOfOfficialDMG() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-homebrew-priority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("Example.app", isDirectory: true).path
        var application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "strict-homebrew",
            token: "example",
            path: path
        )
        application.officialSource = officialSource(
            for: application,
            automaticDiskImage: true
        )
        let registry = providerArbitrationRegistry()

        let provider = await registry.provider(for: application)
        let source = try await provider.inspect(application)

        XCTAssertEqual(provider.identifier, .homebrew)
        XCTAssertTrue(source.canAutomaticallyUpdate)
    }

    func testProviderArbitrationUsesVerifiedOfficialDMGForAutoUpdatesHomebrewCasks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-official-priority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identities = [
            ("CC Switch", "cc-switch", "com.ccswitch.desktop", "R8UR22V2F9"),
            ("draw.io", "drawio", "com.jgraph.drawio.desktop", "UZEUFB4N53"),
        ]
        let registry = providerArbitrationRegistry()
        let sourceRegistry = OfficialSourceRegistry()

        for (name, token, bundleIdentifier, teamIdentifier) in identities {
            let path = root.appendingPathComponent("\(name).app", isDirectory: true).path
            var application = AppUpdateTestFixtures.application(
                id: token,
                name: name,
                bundleIdentifier: bundleIdentifier,
                path: path,
                availableVersion: "2.0",
                signingTeamIdentifier: teamIdentifier,
                installationSource: .homebrewCask,
                provider: .homebrew,
                status: .updateAvailable,
                sourceEvidence: [
                    "homebrew-cli-json-v2",
                    "homebrew-match:exact-artifact-path",
                    "valid-code-signature",
                ],
                homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(
                    token: token,
                    autoUpdates: true,
                    appBundlePaths: [path]
                )
            )
            let registeredSource = await sourceRegistry.source(for: application)
            application.officialSource = try XCTUnwrap(registeredSource)

            let provider = await registry.provider(for: application)
            let source = try await provider.inspect(application)

            XCTAssertEqual(application.bundleIdentifier, bundleIdentifier)
            XCTAssertEqual(application.signingTeamIdentifier, teamIdentifier)
            XCTAssertEqual(application.officialSource?.expectedBundleIdentifier, bundleIdentifier)
            XCTAssertEqual(application.officialSource?.expectedTeamIdentifier, teamIdentifier)
            XCTAssertEqual(application.officialSource?.capability, .automatic)
            XCTAssertEqual(provider.identifier, .officialWebsite)
            XCTAssertTrue(source.canAutomaticallyUpdate)
        }
    }

    func testProviderArbitrationUsesVerifiedOfficialDMGWhenOrdinaryHomebrewIsManual() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-manual-homebrew-official-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("Example.app", isDirectory: true).path
        var application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "ordinary-manual-homebrew",
            token: "example",
            path: path
        )
        application.sourceEvidence.removeAll { $0 == "homebrew-match:exact-artifact-path" }
        application.sourceEvidence.append("homebrew-match:unique-name-fallback")
        application.officialSource = officialSource(
            for: application,
            automaticDiskImage: true
        )

        let registry = providerArbitrationRegistry()
        let provider = await registry.provider(for: application)
        let source = try await provider.inspect(application)

        XCTAssertEqual(application.homebrewMetadata?.autoUpdates, false)
        XCTAssertEqual(provider.identifier, .officialWebsite)
        XCTAssertTrue(source.canAutomaticallyUpdate)
    }

    func testProviderArbitrationPrefersVerifiedOfficialDMGOverSparkleDeclaration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-official-over-sparkle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var application = AppUpdateTestFixtures.application(
            id: "sparkle-official",
            name: "Sparkle Official",
            bundleIdentifier: "com.example.sparkle-official",
            path: root.appendingPathComponent("Sparkle Official.app", isDirectory: true).path,
            availableVersion: "2.0",
            provider: .manual,
            status: .updateAvailable,
            sourceEvidence: ["sparkle-framework", "sparkle-feed", "valid-code-signature"]
        )
        application.feedURL = "https://example.com/appcast.xml"
        application.officialSource = officialSource(for: application, automaticDiskImage: true)

        let registry = providerArbitrationRegistry()
        let provider = await registry.provider(for: application)

        XCTAssertEqual(provider.identifier, ApplicationUpdateProviderIdentifier.officialWebsite)
        let source = try await provider.inspect(application)
        XCTAssertTrue(source.canAutomaticallyUpdate)
    }

    func testProviderArbitrationUsesStrictHomebrewForClaudeWithoutVerifiedOfficialDMG() async throws {
        let application = AppUpdateTestFixtures.application(
            id: "claude",
            name: "Claude",
            bundleIdentifier: "com.anthropic.claudefordesktop",
            path: "/Applications/Claude.app",
            availableVersion: "1.24012.9",
            signingTeamIdentifier: "Q6L2SF6YDW",
            installationSource: .homebrewCask,
            provider: .homebrew,
            status: .updateAvailable,
            sourceEvidence: [
                "homebrew-cli-json-v2",
                "homebrew-match:exact-artifact-path",
                "valid-code-signature",
            ],
            homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(
                token: "claude",
                autoUpdates: true,
                appBundlePaths: ["/Applications/Claude.app"]
            )
        )

        let registeredSource = await OfficialSourceRegistry().source(for: application)
        let provider = await providerArbitrationRegistry().provider(for: application)
        let source = try await provider.inspect(application)

        XCTAssertEqual(application.bundleIdentifier, "com.anthropic.claudefordesktop")
        XCTAssertEqual(application.signingTeamIdentifier, "Q6L2SF6YDW")
        XCTAssertNil(registeredSource)
        XCTAssertEqual(provider.identifier, .homebrew)
        XCTAssertTrue(source.canAutomaticallyUpdate)
        XCTAssertFalse(source.requiresUserInteraction)
    }

    func testHomebrewProviderOnlyMarksExactCaskMatchAutomatic() async throws {
        let metadata = AppUpdateTestFixtures.homebrewMetadata()
        let exact = AppUpdateTestFixtures.application(
            availableVersion: nil,
            provider: .homebrew,
            sourceEvidence: ["homebrew-match:exact-artifact-path", "valid-code-signature"],
            homebrewMetadata: metadata,
            requiresUserInteraction: false
        )
        let fallback = AppUpdateTestFixtures.application(
            availableVersion: nil,
            provider: .homebrew,
            sourceEvidence: ["homebrew-match:unique-name-fallback"],
            homebrewMetadata: metadata,
            requiresUserInteraction: false
        )
        let provider = HomebrewProvider(
            homebrewExecutableProvider: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }
        )

        let exactInfo = try await provider.inspect(exact)
        let exactCheck = try await provider.checkForUpdate(exact)
        let fallbackInfo = try await provider.inspect(fallback)
        let fallbackCheck = try await provider.checkForUpdate(fallback)

        XCTAssertTrue(exactInfo.canAutomaticallyUpdate)
        XCTAssertEqual(exactCheck.status, .automaticallyUpdatable)
        XCTAssertFalse(fallbackInfo.canAutomaticallyUpdate)
        XCTAssertEqual(fallbackCheck.status, .updateAvailable)
        XCTAssertNotNil(fallbackCheck.warning)
    }

    func testHomebrewProviderRejectsInvalidFormulaAndCaskTokensBeforeInstall() async throws {
        let provider = HomebrewProvider()

        for (kind, token) in [(HomebrewPackageKind.formula, "formula;invalid"), (.cask, "-invalid-cask")] {
            var application = AppUpdateTestFixtures.strictHomebrewApplication(id: "invalid-\(kind.rawValue)")
            application.installationSource = kind == .formula ? .homebrewFormula : .homebrewCask
            application.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(
                token: token,
                kind: kind,
                appBundlePaths: kind == .cask ? [application.path] : []
            )
            application.caskToken = kind == .cask ? token : nil

            let source = try await provider.inspect(application)
            XCTAssertFalse(source.canAutomaticallyUpdate)
            do {
                _ = try await provider.prepareUpdate(application)
                XCTFail("Invalid Homebrew token must not be prepared")
            } catch ApplicationScanningError.providerUnsupported {
                // Rejected before locating or launching Homebrew.
            }

            let prepared = PreparedApplicationUpdate(
                applicationID: application.id,
                providerIdentifier: .homebrew,
                originalIdentity: application.identity,
                originalVersion: application.installedVersion,
                targetVersion: application.availableVersion,
                providerPayload: [
                    "brewExecutable": "/bin/false",
                    "token": token,
                    "kind": kind.rawValue,
                ]
            )
            do {
                _ = try await provider.install(prepared) { _ in }
                XCTFail("Invalid Homebrew token must not start a process")
            } catch ApplicationScanningError.providerUnsupported {
                // Rejected by the shared token policy before command execution.
            }
        }
    }

    func testHomebrewCapabilityProbeDoesNotPromiseAutomaticUpdateWithoutTrustedExecutable() async throws {
        let application = AppUpdateTestFixtures.strictHomebrewApplication(id: "missing-brew")
        let provider = HomebrewProvider(homebrewExecutableProvider: { nil })

        let source = try await provider.inspect(application)
        let check = try await provider.checkForUpdate(application)

        XCTAssertFalse(source.canAutomaticallyUpdate)
        XCTAssertTrue(source.requiresUserInteraction)
        XCTAssertEqual(check.status, .updateAvailable)
        XCTAssertNotNil(check.warning)
    }

    func testHomebrewProviderRunsOnlyPreparedStructuredFormulaAndCaskArguments() async throws {
        let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let recorder = RecordingHomebrewUpdateCapture()
        let provider = HomebrewProvider(
            homebrewExecutableProvider: { executableURL },
            environmentProvider: {
                [
                    "HOME": "/Users/example",
                    "TMPDIR": "/private/tmp/example",
                    "USER": "example",
                    "LANG": "en_AU.UTF-8",
                    "SHELL": "/bin/zsh",
                    "UNSAFE_EXTRA": "must-not-pass",
                ]
            },
            commandCapture: { executable, arguments, environment, _ in
                recorder.recordCommand(
                    executableURL: executable,
                    arguments: arguments,
                    environment: environment
                )
                return "updated"
            }
        )
        let cask = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "structured-cask",
            token: "structured-cask"
        )
        var formula = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "structured-formula",
            token: "structured-formula"
        )
        formula.installationSource = .homebrewFormula
        formula.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(
            token: "structured-formula",
            kind: .formula,
            appBundlePaths: []
        )
        formula.caskToken = nil

        for application in [cask, formula] {
            let prepared = try await provider.prepareUpdate(application)
            let recipe = try XCTUnwrap(prepared.executionRecipe)
            XCTAssertEqual(recipe.sourceProvider, .homebrew)
            XCTAssertEqual(recipe.executableURL, executableURL)
            XCTAssertEqual(recipe.currentVersion, application.installedVersion)
            XCTAssertEqual(recipe.expectedBundleIdentifier, application.bundleIdentifier)
            XCTAssertEqual(
                recipe.expectedTeamIdentifier,
                application.signingTeamIdentifier
            )
            XCTAssertTrue(recipe.verificationSteps.contains(.installedVersion))
            XCTAssertTrue(recipe.verificationSteps.contains(.trustedExecutable))
            XCTAssertFalse(recipe.arguments.contains("--greedy"))

            let result = try await provider.install(prepared) { event in
                recorder.recordProgress(event)
            }
            XCTAssertEqual(result.state, .needsReconciliation)
        }

        let invocations = recorder.commands
        XCTAssertEqual(invocations.map(\.arguments), [
            ["upgrade", "--cask", "structured-cask"],
            ["upgrade", "structured-formula"],
        ])
        XCTAssertTrue(invocations.allSatisfy { $0.executableURL == executableURL })
        XCTAssertTrue(invocations.allSatisfy {
            Set($0.environment.keys).isSubset(of: HomebrewUpdateRecipeBuilder.allowedEnvironmentKeys)
                && $0.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1"
                && $0.environment["HOMEBREW_NO_ANALYTICS"] == "1"
                && $0.environment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1"
                && $0.environment["NONINTERACTIVE"] == "1"
                && $0.environment["UNSAFE_EXTRA"] == nil
                && $0.environment["SHELL"] == nil
        })
        XCTAssertEqual(recorder.progressStates, [
            .installing, .verifying,
            .installing, .verifying,
        ])
    }

    func testAppStoreProviderNeverClaimsAutomaticUpdateWithoutCatalogMatch() async throws {
        let application = AppUpdateTestFixtures.application(sourceEvidence: [
            "app-store-receipt",
            "verified-app-store-receipt",
            "valid-code-signature",
            "signed-bundle-identity",
            "app-sandbox-entitlement",
        ])
        let provider = MacAppStoreProvider(
            receiptVerifier: FixedMacAppStoreReceiptVerifier(result: true),
            catalogResolver: FixedAppStoreCatalogResolver(resolution: .notFound)
        )

        let info = try await provider.inspect(application)
        let check = try await provider.checkForUpdate(application)

        XCTAssertFalse(info.canAutomaticallyUpdate)
        XCTAssertTrue(info.requiresUserInteraction)
        XCTAssertEqual(check.status, .appStoreManaged)
        XCTAssertNil(check.availableVersion)
    }

    func testAppStoreProviderAlwaysHandsOffToSystemAppStore() async throws {
        let productID: UInt64 = 123_456_789
        let productURL = try XCTUnwrap(URL(string: "https://apps.apple.com/app/id\(productID)"))
        let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mas")
        let recorder = RecordingHomebrewUpdateCapture()
        var application = AppUpdateTestFixtures.application(
            id: "app-store-structured",
            bundleIdentifier: "com.example.store",
            path: "/Applications/Example.app",
            version: "1.0",
            installationSource: .appStore,
            provider: .macAppStore,
            status: .updateAvailable,
            sourceEvidence: [
                "app-store-receipt",
                "verified-app-store-receipt",
                "valid-code-signature",
                "signed-bundle-identity",
                "app-sandbox-entitlement",
            ]
        )
        let record = AppStoreOutdatedInfo(
            currentVersion: "1.0",
            latestVersion: "2.0",
            productID: productID,
            bundleURL: application.bundleURL
        )
        let provider = MacAppStoreProvider(
            receiptVerifier: FixedMacAppStoreReceiptVerifier(result: true),
            catalogResolver: FixedAppStoreCatalogResolver(resolution: .matched(
                AppStoreCatalogEntry(
                    bundleIdentifier: application.bundleIdentifier,
                    version: ApplicationVersion(marketing: "2.0"),
                    productURL: productURL,
                    sellerName: nil,
                    releaseDate: nil,
                    releaseNotes: nil,
                    downloadSize: nil
                )
            )),
            masExecutableProvider: { executableURL },
            outdatedProvider: { [application, record] in
                [application.bundleIdentifier: record]
            },
            environmentProvider: {
                [
                    "HOME": "/Users/example",
                    "TMPDIR": "/private/tmp/example",
                    "LANG": "en_AU.UTF-8",
                    "UNSAFE_EXTRA": "must-not-pass",
                ]
            },
            commandCapture: { executable, arguments, environment, _ in
                recorder.recordCommand(
                    executableURL: executable,
                    arguments: arguments,
                    environment: environment
                )
                return "updated"
            }
        )

        let source = try await provider.inspect(application)
        let check = try await provider.checkForUpdate(application)
        XCTAssertFalse(source.canAutomaticallyUpdate)
        XCTAssertTrue(source.requiresUserInteraction)
        XCTAssertEqual(check.status, .updateAvailable)
        XCTAssertEqual(check.availableVersion, ApplicationVersion(marketing: "2.0"))

        application = await ApplicationUpdateProviderRegistry(providers: [provider])
            .classify(application)
        XCTAssertEqual(application.updateProvider, .macAppStore)
        XCTAssertEqual(application.updateStatus, .updateAvailable)
        XCTAssertEqual(application.effectiveUpdateCapability, .appStoreManaged)
        XCTAssertFalse(application.canAutomaticallyUpdate)
        XCTAssertTrue(application.requiresUserInteraction)

        let executionPlan = ApplicationUpdatePlanBuilder().build(applications: [application])
        XCTAssertTrue(executionPlan.automaticApplicationIDs.isEmpty)
        XCTAssertEqual(executionPlan.appStoreApplicationIDs, [application.id])
        let oneClickPlan = AppUpdateService.oneClickPlan(for: [application])
        XCTAssertTrue(oneClickPlan.automaticApps.isEmpty)
        XCTAssertEqual(oneClickPlan.appStoreApps.map(\.id), [application.id])
        XCTAssertTrue(recorder.commands.isEmpty)

        do {
            _ = try await provider.prepareUpdate(application)
            XCTFail("App Store updates must require the system App Store confirmation flow")
        } catch {
            XCTAssertTrue(recorder.commands.isEmpty)
        }
    }

    func testAppStoreProviderFailsClosedForIdentityOrVersionMismatch() async throws {
        let expectedProductID: UInt64 = 123_456_789
        let productURL = try XCTUnwrap(
            URL(string: "https://apps.apple.com/app/id\(expectedProductID)")
        )
        let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mas")
        let expectedPath = URL(fileURLWithPath: "/Applications/Example.app", isDirectory: true)
        let cases: [(
            name: String,
            productID: UInt64,
            path: URL,
            current: String,
            target: String,
            catalogTarget: String
        )] = [
            ("adam-id", 987_654_321, expectedPath, "1.0", "2.0", "2.0"),
            ("path", expectedProductID, URL(fileURLWithPath: "/Applications/Other.app"), "1.0", "2.0", "2.0"),
            ("current-version", expectedProductID, expectedPath, "0.9", "2.0", "2.0"),
            ("target-version", expectedProductID, expectedPath, "1.0", "2.1", "2.0"),
            ("catalog-version", expectedProductID, expectedPath, "1.0", "2.0", "2.1"),
        ]

        for testCase in cases {
            let recorder = RecordingHomebrewUpdateCapture()
            var application = AppUpdateTestFixtures.application(
                id: "app-store-mismatch-\(testCase.name)",
                bundleIdentifier: "com.example.store",
                path: expectedPath.path,
                version: "1.0",
                installationSource: .appStore,
                provider: .macAppStore,
                status: .updateAvailable,
                sourceEvidence: [
                    "app-store-receipt",
                    "verified-app-store-receipt",
                    "valid-code-signature",
                    "signed-bundle-identity",
                ]
            )
            let record = AppStoreOutdatedInfo(
                currentVersion: testCase.current,
                latestVersion: testCase.target,
                productID: testCase.productID,
                bundleURL: testCase.path
            )
            let provider = MacAppStoreProvider(
                receiptVerifier: FixedMacAppStoreReceiptVerifier(result: true),
                catalogResolver: FixedAppStoreCatalogResolver(resolution: .matched(
                    AppStoreCatalogEntry(
                        bundleIdentifier: application.bundleIdentifier,
                        version: ApplicationVersion(marketing: testCase.catalogTarget),
                        productURL: productURL,
                        sellerName: nil,
                        releaseDate: nil,
                        releaseNotes: nil,
                        downloadSize: nil
                    )
                )),
                masExecutableProvider: { executableURL },
                outdatedProvider: { [application, record] in
                    [application.bundleIdentifier: record]
                },
                commandCapture: { executable, arguments, environment, _ in
                    recorder.recordCommand(
                        executableURL: executable,
                        arguments: arguments,
                        environment: environment
                    )
                    return "must-not-run"
                }
            )

            let source = try await provider.inspect(application)
            let check = try await provider.checkForUpdate(application)
            XCTAssertNotEqual(check.status, .automaticallyUpdatable, testCase.name)

            application.availableVersion = check.availableVersion
            application.appStoreProductURL = check.appStoreProductURL
            application.updateStatus = .automaticallyUpdatable
            application.updateCapability = .automatic
            application.canAutomaticallyUpdate = true
            application.requiresUserInteraction = false
            application.sourceEvidence.append(contentsOf: source.evidence)

            do {
                _ = try await provider.prepareUpdate(application)
                XCTFail("Mismatched \(testCase.name) must not produce an update recipe")
            } catch {
                XCTAssertTrue(recorder.commands.isEmpty, testCase.name)
            }
        }
    }

    func testAppStoreOutdatedParserPreservesAdamIDAndBundlePath() throws {
        let output = #"{"bundleID":"com.example.store","version":"1.0","newVersion":"2.0","adamID":123456789,"path":"/Applications/Example.app"}"#

        let record = try XCTUnwrap(
            AppUpdateService.appStoreOutdatedByBundleIdentifier(from: output)["com.example.store"]
        )

        XCTAssertEqual(record.currentVersion, "1.0")
        XCTAssertEqual(record.latestVersion, "2.0")
        XCTAssertEqual(record.productID, 123_456_789)
        XCTAssertEqual(record.bundleURL?.path, "/Applications/Example.app")
    }

    func testAppStoreOutdatedMergeFillsMissingProductURLFromExactAdamID() throws {
        let application = AppUpdateTestFixtures.application(
            bundleIdentifier: "com.example.store",
            path: "/Applications/Example.app",
            version: "1.0",
            installationSource: .appStore,
            provider: .macAppStore,
            sourceEvidence: [
                "verified-app-store-receipt",
                "valid-code-signature",
                "signed-bundle-identity",
            ]
        )
        let merged = try XCTUnwrap(AppUpdateService.mergingAppStoreOutdated(
            [application.bundleIdentifier: AppStoreOutdatedInfo(
                currentVersion: "1.0",
                latestVersion: "2.0",
                productID: 123_456_789,
                bundleURL: application.bundleURL
            )],
            into: [application]
        ).first)

        XCTAssertEqual(
            merged.appStoreProductURL,
            URL(string: "https://apps.apple.com/app/id123456789")
        )
    }

    func testAppStoreReceiptAloneIsNotTrustedAsProviderEvidence() async {
        let application = AppUpdateTestFixtures.application(sourceEvidence: ["app-store-receipt"])
        let provider = MacAppStoreProvider(receiptVerifier: FixedMacAppStoreReceiptVerifier(result: true))

        let canHandle = await provider.canHandle(application)
        XCTAssertFalse(canHandle)
    }

    func testAppStoreProviderRejectsApplicationWhenReceiptVerificationFails() async {
        let application = AppUpdateTestFixtures.application(sourceEvidence: [
            "app-store-receipt",
            "verified-app-store-receipt",
            "valid-code-signature",
            "signed-bundle-identity",
        ])
        let provider = MacAppStoreProvider(receiptVerifier: FixedMacAppStoreReceiptVerifier(result: false))

        let canHandle = await provider.canHandle(application)
        XCTAssertFalse(canHandle)
    }

    func testAppStoreReceiptPayloadBindsToExactBundleIdentifier() throws {
        let payload = AppStoreReceiptDERFixture.payload(
            attributes: [
                (type: 12, value: Data([0x02, 0x01, 0x01])),
                (type: 2, value: AppStoreReceiptDERFixture.utf8String("com.example.store")),
            ]
        )

        XCTAssertEqual(
            MacAppStoreReceiptPayloadParser.bundleIdentifier(from: payload),
            "com.example.store"
        )
        XCTAssertTrue(MacAppStoreReceiptPayloadParser.receipt(
            payload: payload,
            matchesBundleIdentifier: "com.example.store"
        ))
        XCTAssertFalse(MacAppStoreReceiptPayloadParser.receipt(
            payload: payload,
            matchesBundleIdentifier: "com.example.lookalike"
        ))
    }

    func testAppStoreReceiptPayloadRejectsMalformedOrWrongAttributeEncoding() {
        let wrongEncoding = AppStoreReceiptDERFixture.payload(attributes: [
            (type: 2, value: AppStoreReceiptDERFixture.octetString(Data("com.example.store".utf8))),
        ])
        let truncated = Data([0x31, 0x05, 0x30, 0x03, 0x02])
        let validPayload = AppStoreReceiptDERFixture.payload(attributes: [
            (type: 2, value: AppStoreReceiptDERFixture.utf8String("com.example.store")),
        ])

        XCTAssertNil(MacAppStoreReceiptPayloadParser.bundleIdentifier(from: wrongEncoding))
        XCTAssertNil(MacAppStoreReceiptPayloadParser.bundleIdentifier(from: truncated))
        XCTAssertNil(MacAppStoreReceiptPayloadParser.bundleIdentifier(from: validPayload + Data([0x00])))
    }

    func testHomebrewCaskRequiresActualArtifactPathAndSignedIdentity() async throws {
        let provider = HomebrewProvider(
            homebrewExecutableProvider: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }
        )
        let metadata = AppUpdateTestFixtures.homebrewMetadata(
            appBundlePaths: ["/Applications/Expected.app"]
        )
        let application = AppUpdateTestFixtures.application(
            path: "/Applications/Moved.app",
            availableVersion: "2.0",
            provider: .homebrew,
            status: .automaticallyUpdatable,
            sourceEvidence: ["homebrew-match:exact-artifact-path", "valid-code-signature"],
            homebrewMetadata: metadata,
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )

        let info = try await provider.inspect(application)
        XCTAssertFalse(info.canAutomaticallyUpdate)
        XCTAssertFalse(ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(application))
    }

    func testClassificationKeepsSourceResolutionSeparateFromVersionCheckFailure() async {
        let registry = ApplicationUpdateProviderRegistry(providers: [FailingVersionCheckProvider()])

        let classified = await registry.classify(AppUpdateTestFixtures.application())

        XCTAssertEqual(classified.primaryUpdateProvider, .vendorUpdater)
        XCTAssertEqual(classified.updateProvider, .vendorUpdater)
        XCTAssertEqual(classified.sourceResolutionState, .resolved)
        XCTAssertEqual(classified.versionCheckState, .failed)
        // Vendor updaters expose an in-application guidance path; the
        // capability survives a failed remote version check.
        XCTAssertEqual(classified.updateCapability, .inApplication)
        XCTAssertEqual(classified.updateStatus, .failed)
    }

    func testVendorUpdaterDetectionRequiresUnambiguousInBundleMarkers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VendorUpdaterDetection-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        func makeBundle(
            named name: String,
            plistExtras: [String: Any] = [:],
            frameworks: [String] = []
        ) throws -> URL {
            let bundleURL = root.appendingPathComponent(name, isDirectory: true)
            let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(
                at: contents,
                withIntermediateDirectories: true
            )
            var info: [String: Any] = [
                "CFBundleIdentifier": "com.example.\(name)",
                "CFBundleShortVersionString": "1.0",
            ]
            plistExtras.forEach { info[$0.key] = $0.value }
            let data = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            for framework in frameworks {
                try FileManager.default.createDirectory(
                    at: contents
                        .appendingPathComponent("Frameworks", isDirectory: true)
                        .appendingPathComponent(framework, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            return bundleURL
        }

        let keystoneBundle = try makeBundle(
            named: "Keystone.app",
            plistExtras: ["KSUpdateURL": "https://tools.google.com/service/update2"]
        )
        let squirrelBundle = try makeBundle(
            named: "Squirrel.app",
            frameworks: ["Squirrel.framework"]
        )
        let plainBundle = try makeBundle(named: "Plain.app")

        XCTAssertEqual(
            VendorUpdaterProvider.detectUpdaterKinds(at: keystoneBundle),
            [.keystone]
        )
        XCTAssertEqual(
            VendorUpdaterProvider.detectUpdaterKinds(at: squirrelBundle),
            [.squirrel]
        )
        XCTAssertTrue(VendorUpdaterProvider.detectUpdaterKinds(at: plainBundle).isEmpty)
    }

    func testVendorUpdaterClassificationYieldsInApplicationGuidanceWithoutVersionClaims() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VendorUpdaterClassify-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Chrome.app", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.chrome",
            "KSProductID": "com.example.chrome",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let registry = ApplicationUpdateProviderRegistry(
            providers: [VendorUpdaterProvider(), ManualUpdateProvider()]
        )
        let classified = await registry.classify(
            AppUpdateTestFixtures.application(
                bundleIdentifier: "com.example.chrome",
                path: bundleURL.path
            )
        )

        XCTAssertEqual(classified.primaryUpdateProvider, .vendorUpdater)
        XCTAssertEqual(classified.sourceResolutionState, .resolved)
        XCTAssertEqual(classified.updateStatus, .latestVersionUnknown)
        XCTAssertEqual(classified.updateCapability, .inApplication)
        XCTAssertNil(classified.availableVersion)
        XCTAssertFalse(classified.canAutomaticallyUpdate)
        XCTAssertTrue(classified.sourceEvidence.contains("vendor-keystone"))
        XCTAssertFalse(ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(classified))
    }

    func testManualFallbackNeedsSourceConfirmationAndLeavesVersionUnavailable() async {
        let classified = await ApplicationUpdateProviderRegistry(
            providers: [ManualUpdateProvider()]
        ).classify(AppUpdateTestFixtures.application())

        XCTAssertEqual(classified.primaryUpdateProvider, .manual)
        XCTAssertEqual(classified.sourceResolutionState, .needsConfirmation)
        XCTAssertEqual(classified.versionCheckState, .unavailable)
        XCTAssertEqual(classified.updateCapability, .unavailable)
        XCTAssertNil(classified.availableVersion)
    }

    func testSparkleWithoutCatalogVersionIsNotReportedAsUpdateAvailable() async {
        let application = AppUpdateTestFixtures.application(
            sourceEvidence: ["sparkle-framework"]
        )
        let classified = await ApplicationUpdateProviderRegistry(
            providers: [SparkleProvider(), ManualUpdateProvider()]
        ).classify(application)

        XCTAssertEqual(classified.primaryUpdateProvider, .sparkle)
        XCTAssertEqual(classified.sourceResolutionState, .resolved)
        XCTAssertEqual(classified.versionCheckState, .unavailable)
        XCTAssertEqual(classified.updateCapability, .inApplication)
        XCTAssertEqual(classified.updateStatus, .latestVersionUnknown)
        XCTAssertNil(classified.availableVersion)
    }

    func testLegacyApplicationUpdateRequiredWithoutVersionInfersUnavailable() {
        let legacy = AppUpdateTestFixtures.application(
            availableVersion: nil,
            provider: .sparkle,
            status: .applicationUpdateRequired
        )

        XCTAssertEqual(legacy.versionCheckState, .unavailable)
        XCTAssertEqual(legacy.updateCapability, .inApplication)
    }

    func testAppStoreWithoutCatalogMatchHasUnavailableVersionState() async {
        let application = AppUpdateTestFixtures.application(sourceEvidence: [
            "app-store-receipt",
            "verified-app-store-receipt",
            "valid-code-signature",
            "signed-bundle-identity",
        ])
        let classified = await ApplicationUpdateProviderRegistry(providers: [
            MacAppStoreProvider(
                receiptVerifier: FixedMacAppStoreReceiptVerifier(result: true),
                catalogResolver: FixedAppStoreCatalogResolver(resolution: .notFound)
            ),
            ManualUpdateProvider(),
        ]).classify(application)

        XCTAssertEqual(classified.primaryUpdateProvider, .macAppStore)
        XCTAssertEqual(classified.sourceResolutionState, .resolved)
        XCTAssertEqual(classified.versionCheckState, .unavailable)
        XCTAssertEqual(classified.updateCapability, .appStoreManaged)
        XCTAssertNil(classified.availableVersion)
    }

    func testInstalledApplicationDecodesLegacyProviderKeyWithoutNewStateFields() throws {
        let application = AppUpdateTestFixtures.application(provider: .homebrew)
        let encoded = try JSONEncoder().encode(application)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "sourceResolutionState")
        object.removeValue(forKey: "versionCheckState")
        object.removeValue(forKey: "updateCapability")
        XCTAssertEqual(object["updateProvider"] as? String, "homebrew")
        XCTAssertNil(object["primaryUpdateProvider"])

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(InstalledApplication.self, from: legacyData)

        XCTAssertEqual(decoded.primaryUpdateProvider, .homebrew)
        XCTAssertNil(decoded.sourceResolutionState)
        XCTAssertNil(decoded.versionCheckState)
        XCTAssertNil(decoded.updateCapability)
        XCTAssertEqual(decoded.effectiveSourceResolutionState, .resolved)
        XCTAssertEqual(decoded.effectiveVersionCheckState, .unavailable)
        XCTAssertEqual(decoded.effectiveUpdateCapability, .manual)
    }

    func testPresentationFiltersExcludeSystemAndDoNotDuplicateSparkleCategory() {
        let system = AppUpdateTestFixtures.application(
            id: "system",
            path: "/System/Applications/Example.app",
            provider: .systemManaged,
            status: .systemManaged,
            isSystem: true
        )
        let sparkle = AppUpdateTestFixtures.application(
            id: "sparkle",
            provider: .sparkle,
            status: .latestVersionUnknown,
            sourceEvidence: ["sparkle-framework"]
        )

        XCTAssertFalse(AppUpdateListFilter.all.includes(system))
        XCTAssertTrue(AppUpdateListFilter.systemManaged.includes(system))
        XCTAssertTrue(AppUpdateListFilter.applicationInternal.includes(sparkle))
        XCTAssertFalse(AppUpdateListFilter.sparkle.includes(sparkle))
    }

    func testManualProviderNeedsSourceConfirmationWithoutPretendingToCheckVersion() async {
        let application = AppUpdateTestFixtures.application()
        let classified = await ApplicationUpdateProviderRegistry(
            providers: [ManualUpdateProvider()]
        ).classify(application)

        XCTAssertEqual(classified.primaryUpdateProvider, .manual)
        XCTAssertEqual(classified.sourceResolutionState, .needsConfirmation)
        XCTAssertEqual(classified.versionCheckState, .unavailable)
        XCTAssertEqual(classified.updateCapability, .unavailable)
        XCTAssertTrue(AppUpdateListFilter.sourceUnconfirmed.includes(classified))
        XCTAssertFalse(AppUpdateListFilter.updateAvailable.includes(classified))
    }

    func testSystemPathCannotBeClaimedByAutomaticProviderOrUpdatePlan() async {
        var application = AppUpdateTestFixtures.application(
            path: "/System/Applications/Example.app",
            availableVersion: "2.0",
            provider: .homebrew,
            status: .automaticallyUpdatable,
            sourceEvidence: [
                "homebrew-match:exact-artifact-path",
                "valid-code-signature",
            ],
            homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(
                appBundlePaths: ["/System/Applications/Example.app"]
            ),
            isSystem: false,
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )
        application.installationSource = .standardDirectory
        let registry = ApplicationUpdateProviderRegistry(providers: [HomebrewProvider()])

        let classified = await registry.classify(application)
        let plan = ApplicationUpdatePlanBuilder().build(applications: [application])

        XCTAssertEqual(classified.primaryUpdateProvider, .systemManaged)
        XCTAssertEqual(classified.updateCapability, .systemManaged)
        XCTAssertTrue(classified.isSystemApplication)
        XCTAssertEqual(plan.skippedApplicationIDs, [application.id])
        XCTAssertTrue(plan.automaticApplicationIDs.isEmpty)
    }

    func testAppStoreProviderRequiresExactSigningIdentifierBoundary() async {
        let application = AppUpdateTestFixtures.application(
            codeSigningIdentifier: "com.example.lookalike",
            sourceEvidence: [
                "app-store-receipt",
                "verified-app-store-receipt",
                "valid-code-signature",
                "signed-bundle-identity",
            ]
        )
        let provider = MacAppStoreProvider(
            receiptVerifier: FixedMacAppStoreReceiptVerifier(result: true)
        )

        let canHandle = await provider.canHandle(application)
        XCTAssertFalse(canHandle)
    }

    func testDuplicateGroupingKeepsCopiesVisibleAndBlocksConflictingSignatures() {
        let first = AppUpdateTestFixtures.application(
            id: "first",
            path: "/Applications/Example.app",
            signingTeamIdentifier: "TEAM-A"
        )
        let second = AppUpdateTestFixtures.application(
            id: "second",
            path: "/Users/test/Applications/Example.app",
            signingTeamIdentifier: "TEAM-B"
        )

        let result = ApplicationDeduplicator().process([first, second])

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy(\.isDuplicate))
        XCTAssertTrue(result.allSatisfy { $0.duplicateLocations.count == 2 })
        XCTAssertTrue(result.allSatisfy {
            $0.sourceEvidence.contains("duplicate-signing-identity-conflict")
                && !$0.canAutomaticallyUpdate
                && $0.updateCapability == .manual
        })
    }

    func testIconResolverUsesExistingHomebrewApplicationArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-icon-source-\(UUID().uuidString)", isDirectory: true)
        let actualApplication = root.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: actualApplication,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = AppUpdateTestFixtures.homebrewMetadata(
            appBundlePaths: [actualApplication.path]
        )
        let synthetic = AppUpdateTestFixtures.application(
            path: "/opt/homebrew/Caskroom/example/2.0/Example.app",
            homebrewMetadata: metadata
        )

        XCTAssertEqual(
            ApplicationIconSourceResolver.sourceURL(for: synthetic).standardizedFileURL,
            actualApplication.standardizedFileURL
        )
        XCTAssertEqual(
            ApplicationIconSourceResolver.applicationBundleURL(for: synthetic)?.standardizedFileURL,
            actualApplication.standardizedFileURL
        )
    }

    func testIconResolverDoesNotTreatCommandLineExecutableAsApplicationArtwork() {
        var synthetic = AppUpdateTestFixtures.application(path: "/opt/homebrew/bin/example")
        synthetic.packageKind = .commandLineTool

        XCTAssertNil(ApplicationIconSourceResolver.applicationBundleURL(for: synthetic))
        XCTAssertEqual(
            ApplicationIconSourceResolver.sourceURL(for: synthetic).path,
            "/opt/homebrew/bin/example"
        )
    }

    private func providerArbitrationRegistry() -> ApplicationUpdateProviderRegistry {
        ApplicationUpdateProviderRegistry(providers: [
            SystemManagedProvider(),
            MacAppStoreProvider(receiptVerifier: FixedMacAppStoreReceiptVerifier(result: false)),
            HomebrewProvider(
                homebrewExecutableProvider: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }
            ),
            SparkleProvider(),
            OfficialWebsiteUpdateProvider(),
            ManualUpdateProvider(),
        ])
    }

    private func officialSource(
        for application: InstalledApplication,
        automaticDiskImage: Bool = false
    ) -> OfficialUpdateSource {
        OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialWebsite,
            developerName: "Example",
            homepageURL: URL(string: "https://example.com"),
            updatePageURL: URL(string: "https://example.com/download"),
            releaseFeedURL: nil,
            directDownloadURL: automaticDiskImage
                ? URL(string: "https://example.com/Example.dmg")
                : nil,
            allowedHosts: ["example.com"],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .signedRegistry,
            trustLevel: .registryVerified,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: automaticDiskImage ? .automatic : .manualWebsite,
            expectedPackageExtensions: automaticDiskImage ? ["dmg"] : [],
            officialGitHubRepository: nil
        )
    }
}

private struct HomebrewCommandInvocation: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
}

private struct HomebrewUpdateCommandInvocation: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

private final class RecordingHomebrewUpdateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedCommands: [HomebrewUpdateCommandInvocation] = []
    private var capturedProgressStates: [ApplicationUpdateTaskState] = []

    var commands: [HomebrewUpdateCommandInvocation] {
        lock.withLock { capturedCommands }
    }

    var progressStates: [ApplicationUpdateTaskState] {
        lock.withLock { capturedProgressStates }
    }

    func recordCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) {
        lock.withLock {
            capturedCommands.append(HomebrewUpdateCommandInvocation(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment
            ))
        }
    }

    func recordProgress(_ event: ApplicationUpdateProgressEvent) {
        lock.withLock { capturedProgressStates.append(event.state) }
    }
}

private actor RecordingHomebrewCommandRunner: HomebrewCommandRunning {
    private let response: Data
    private var invocations: [HomebrewCommandInvocation] = []

    init(response: Data) {
        self.response = response
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        invocations.append(HomebrewCommandInvocation(
            executableURL: executableURL.standardizedFileURL,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        ))
        return response
    }

    func recordedInvocations() -> [HomebrewCommandInvocation] {
        invocations
    }
}

private actor ScriptedHomebrewCommandRunner: HomebrewCommandRunning {
    private(set) var invocations: [HomebrewCommandInvocation] = []

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        invocations.append(HomebrewCommandInvocation(
            executableURL: executableURL.standardizedFileURL,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        ))
        switch arguments.first {
        case "--prefix":
            return Data("/opt/homebrew\n".utf8)
        case "info":
            return Data(#"{"formulae":[],"casks":[]}"#.utf8)
        case "outdated":
            return Data(#"{"formulae":[],"casks":[]}"#.utf8)
        default:
            return Data()
        }
    }
}

private struct FailingVersionCheckProvider: ApplicationUpdateProvider {
    let identifier = ApplicationUpdateProviderIdentifier.vendorUpdater

    func canHandle(_ application: InstalledApplication) async -> Bool { true }

    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        ApplicationUpdateSourceInfo(
            providerIdentifier: identifier,
            evidence: ["verified-vendor-adapter"],
            requiresUserInteraction: true,
            canAutomaticallyUpdate: false
        )
    }

    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult {
        throw ApplicationScanningError.providerUnsupported("remote-version-check")
    }
}

private struct FixedMacAppStoreReceiptVerifier: MacAppStoreReceiptVerifying {
    let result: Bool

    func verifyReceipt(at applicationURL: URL) async -> Bool {
        result
    }
}

private struct FixedAppStoreCatalogResolver: AppStoreCatalogResolving {
    let resolution: AppStoreCatalogResolution

    func resolve(
        bundleIdentifier: String,
        storefront: String
    ) async throws -> AppStoreCatalogResolution {
        resolution
    }
}

private enum AppStoreReceiptDERFixture {
    static func payload(attributes: [(type: Int, value: Data)]) -> Data {
        wrap(tag: 0x31, content: attributes.reduce(into: Data()) { result, attribute in
            result.append(wrap(tag: 0x30, content:
                integer(attribute.type)
                + integer(1)
                + octetString(attribute.value)
            ))
        })
    }

    static func utf8String(_ value: String) -> Data {
        wrap(tag: 0x0C, content: Data(value.utf8))
    }

    static func octetString(_ value: Data) -> Data {
        wrap(tag: 0x04, content: value)
    }

    private static func integer(_ value: Int) -> Data {
        precondition((0...127).contains(value))
        return Data([0x02, 0x01, UInt8(value)])
    }

    private static func wrap(tag: UInt8, content: Data) -> Data {
        precondition(content.count < 128)
        return Data([tag, UInt8(content.count)]) + content
    }
}
