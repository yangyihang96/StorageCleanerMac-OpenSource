import Foundation
import XCTest
@testable import StorageCleanerMac

final class StartupScanningTests: XCTestCase {
    func testLaunchdScannerParsesCustomDirectoryAndKeepsMalformedPlist() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("com.example.agent.plist")
        let malformed = root.appendingPathComponent("broken.plist")
        let executable = root.appendingPathComponent("helper")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "com.example.agent",
                "ProgramArguments": [executable.path, "--background"],
                "KeepAlive": ["SuccessfulExit": false],
            ],
            format: .xml,
            options: 0
        ).write(to: valid)
        try Data("not a plist".utf8).write(to: malformed)

        let scanner = LaunchdPlistScanner(
            location: .custom(directory: root, kind: .userLaunchAgent, scope: .currentUser)
        )
        let result = try await scanner.scan(context: StartupScanContext(
            homeDirectory: root,
            applicationDirectories: [],
            includeBackgroundTaskDiagnostic: false
        ))

        XCTAssertEqual(result.count, 2)
        let parsed = try XCTUnwrap(result.first { $0.label == "com.example.agent" })
        XCTAssertEqual(parsed.configuration?.programArguments, [executable.path, "--background"])
        XCTAssertEqual(parsed.configuration?.keepAlive, true)
        XCTAssertTrue(parsed.configuration?.triggers.contains(.keepAlive) == true)
        XCTAssertEqual(parsed.state.enablement, .unknown)
        XCTAssertTrue(result.contains { $0.diagnosticEvidence.contains(where: { $0.hasPrefix("malformed-plist:") }) })
    }

    func testAllFiveStandardLaunchdLocationsHaveCorrectKindAndScope() {
        let context = StartupScanContext(homeDirectory: URL(fileURLWithPath: "/Users/test"))
        let expectations: [(LaunchdScanLocation, String, StartupItemsDomain.ItemKind, StartupItemsDomain.Scope)] = [
            (.userLaunchAgents, "/Users/test/Library/LaunchAgents", .userLaunchAgent, .currentUser),
            (.globalLaunchAgents, "/Library/LaunchAgents", .globalLaunchAgent, .allUsers),
            (.systemLaunchAgents, "/System/Library/LaunchAgents", .systemLaunchAgent, .system),
            (.launchDaemons, "/Library/LaunchDaemons", .launchDaemon, .allUsers),
            (.systemLaunchDaemons, "/System/Library/LaunchDaemons", .systemLaunchDaemon, .system),
        ]
        for (location, path, kind, scope) in expectations {
            XCTAssertEqual(location.directory(in: context).path, path)
            XCTAssertEqual(location.kind, kind)
            XCTAssertEqual(location.scope, scope)
        }
    }

    func testBackgroundDiagnosticIsOptInToAvoidAuthorizationPromptOnPageOpen() async throws {
        let runner = RecordingStartupRunner(responses: [])
        let scanner = BackgroundTaskManagementScanner(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: runner
        )

        let candidates = try await scanner.scan(context: StartupScanContext(applicationDirectories: []))
        let recordedArguments = await runner.recordedArguments()

        XCTAssertTrue(candidates.isEmpty)
        XCTAssertTrue(recordedArguments.isEmpty)
    }

    func testBackgroundDiagnosticUsesOnlyDumpBTMAndMapsSystemSettingsCapability() async throws {
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        let runner = RecordingStartupRunner(responses: [
            StartupCommandResult(
                terminationStatus: 0,
                standardOutput: """
                UUID: 00000000-0000-0000-0000-000000000001
                Identifier: com.example.helper
                Name: Example Helper
                Bundle Identifier: com.example.app
                Team Identifier: TEAM123
                Type: agent
                Disposition: enabled allowed
                """,
                standardError: ""
            ),
        ])
        let scanner = BackgroundTaskManagementScanner(executableURL: executable, runner: runner)
        let candidates = try await scanner.scan(context: StartupScanContext(
            applicationDirectories: [],
            includeBackgroundTaskDiagnostic: true
        ))

        let recordedArguments = await runner.recordedArguments()
        let recordedTimeouts = await runner.recordedTimeouts()
        XCTAssertEqual(recordedArguments, [["dumpbtm"]])
        XCTAssertEqual(recordedTimeouts.count, 1)
        XCTAssertGreaterThan(recordedTimeouts[0], 0)
        XCTAssertLessThanOrEqual(recordedTimeouts[0], 30)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].state.management, .manageableInSystemSettings)
        XCTAssertFalse(candidates[0].actionCapability.canDisableDirectly)
        XCTAssertTrue(candidates[0].actionCapability.canOpenSystemSettings)
        XCTAssertEqual(candidates[0].attribution?.confidence, .verified)
    }

    func testEnabledBTMAppIsOpenAtLoginWhileDisabledAppRemainsBackgroundEvidence() async throws {
        let runner = RecordingStartupRunner(responses: [
            StartupCommandResult(
                terminationStatus: 0,
                standardOutput: """
                UUID: 00000000-0000-0000-0000-000000000101
                Identifier: 2.com.example.enabled
                Name: Enabled App
                Bundle Identifier: com.example.enabled
                Type: app (0x2)
                Disposition: enabled allowed notified

                UUID: 00000000-0000-0000-0000-000000000102
                Identifier: 2.com.example.disabled
                Name: Disabled App
                Bundle Identifier: com.example.disabled
                Type: app (0x2)
                Disposition: disabled allowed notified
                """,
                standardError: ""
            ),
        ])
        let scanner = BackgroundTaskManagementScanner(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: runner
        )

        let candidates = try await scanner.scan(context: StartupScanContext(
            applicationDirectories: [],
            includeBackgroundTaskDiagnostic: true
        ))

        XCTAssertEqual(candidates.first { $0.name == "Enabled App" }?.kind, .openAtLogin)
        XCTAssertEqual(candidates.first { $0.name == "Disabled App" }?.kind, .appBackgroundTask)
    }

    @MainActor
    func testScanStoreKeepsBackgroundDiagnosticExplicitAndBounded() async throws {
        let runner = RecordingStartupRunner(responses: [
            StartupCommandResult(
                terminationStatus: 1,
                standardOutput: "",
                standardError: "authorization denied"
            ),
        ])
        let coordinator = StartupScanCoordinator(
            primaryScanners: [
                FixedStartupScanner(
                    source: .launchdPlist,
                    identifier: "other-source",
                    outcome: .success([fixtureCandidate(label: "com.example.agent")])
                ),
                BackgroundTaskManagementScanner(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    runner: runner
                ),
            ],
            secondaryScannerFactory: { _ in [] }
        )
        let store = ScanStore(startupScanCoordinator: coordinator)

        store.refreshStartupItems()
        try await waitForStartupScan(store)
        let defaultArguments = await runner.recordedArguments()
        XCTAssertTrue(defaultArguments.isEmpty)
        XCTAssertFalse(store.startupCoverage.managedItemCoverageAvailable)

        store.refreshStartupItems(includeBackgroundTaskDiagnostic: true)
        try await waitForStartupScan(store)

        let explicitArguments = await runner.recordedArguments()
        let explicitTimeouts = await runner.recordedTimeouts()
        XCTAssertEqual(explicitArguments, [["dumpbtm"]])
        let timeout = try XCTUnwrap(explicitTimeouts.first)
        XCTAssertEqual(timeout, 60)
        XCTAssertEqual(store.startupDomainItems.count, 1)
        XCTAssertFalse(store.startupCoverage.managedItemCoverageAvailable)
        XCTAssertTrue(
            store.startupCoverage.sources.first(where: {
                $0.source == .backgroundTaskDiagnostic
            })?.errorDescription?.contains("authorization denied") == true
        )
    }

    func testVerifiedBTMParentIdentifierEnrichesExactInstalledApplication() async throws {
        let runner = RecordingStartupRunner(responses: [
            StartupCommandResult(
                terminationStatus: 0,
                standardOutput: """
                UUID: 00000000-0000-0000-0000-000000000011
                Identifier: com.example.helper
                Name: Helper Process
                Bundle Identifier: com.example.helper
                Parent Identifier: com.example.parent
                Team Identifier: HELPERTEAM
                Type: agent
                Disposition: enabled allowed
                """,
                standardError: ""
            ),
        ])
        let scanner = BackgroundTaskManagementScanner(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: runner
        )
        let scanned = try await scanner.scan(context: StartupScanContext(
            applicationDirectories: [],
            includeBackgroundTaskDiagnostic: true
        ))
        let candidate = try XCTUnwrap(scanned.first)
        let parentURL = URL(fileURLWithPath: "/Applications/Parent.app")
        let index = InstalledApplicationIndex(applications: [
            StartupInstalledApplication(
                bundleIdentifier: "com.example.parent",
                bundleURL: parentURL,
                executableURL: parentURL.appendingPathComponent("Contents/MacOS/Parent"),
                displayName: "Parent Application",
                developerName: "Parent Developer",
                teamIdentifier: "PARENTTEAM",
                codeSigningIdentifier: "com.example.parent",
                designatedRequirement: "identifier com.example.parent"
            ),
        ])

        let resolved = StartupAttributionResolver().resolve(candidate, using: index)

        XCTAssertEqual(resolved.attribution?.applicationBundleIdentifier, "com.example.parent")
        XCTAssertEqual(resolved.attribution?.applicationName, "Parent Application")
        XCTAssertEqual(resolved.attribution?.developerName, "Parent Developer")
        XCTAssertEqual(resolved.attribution?.teamIdentifier, "PARENTTEAM")
        XCTAssertEqual(resolved.attribution?.applicationURL, parentURL)
        XCTAssertTrue(resolved.attribution?.evidence.contains(where: {
            $0.kind == .backgroundTaskManagement && $0.confidence == .verified
        }) == true)
        XCTAssertTrue(resolved.attribution?.evidence.contains(where: {
            $0.kind == .installedApplicationIndex && $0.value == "com.example.parent"
        }) == true)
    }

    func testAmbiguousBTMParentCopiesDoNotInheritArbitraryApplicationMetadata() {
        var candidate = fixtureCandidate(label: "com.example.helper")
        candidate.source = .backgroundTaskDiagnostic
        candidate.attribution = StartupItemsDomain.Attribution(
            applicationBundleIdentifier: "com.example.parent",
            applicationURL: nil,
            applicationName: "Helper Process",
            developerName: nil,
            teamIdentifier: "TEAM123",
            designatedRequirement: nil,
            evidence: [
                .init(kind: .backgroundTaskManagement, value: "com.example.parent", confidence: .verified),
            ]
        )
        let applications = ["/Applications/Parent.app", "/Volumes/External/Parent.app"].map { path in
            StartupInstalledApplication(
                bundleIdentifier: "com.example.parent",
                bundleURL: URL(fileURLWithPath: path),
                executableURL: nil,
                displayName: "Parent",
                developerName: "Example",
                teamIdentifier: "TEAM123",
                codeSigningIdentifier: "com.example.parent",
                designatedRequirement: nil
            )
        }

        let resolved = StartupAttributionResolver().resolve(
            candidate,
            using: InstalledApplicationIndex(applications: applications)
        )

        XCTAssertEqual(resolved.attribution?.applicationName, "Helper Process")
        XCTAssertNil(resolved.attribution?.applicationURL)
        XCTAssertNil(resolved.applicationURL)
        XCTAssertFalse(resolved.attribution?.evidence.contains(where: {
            $0.kind == .installedApplicationIndex
        }) == true)
    }

    func testAmbiguousAssociatedBundleIdentifierPreservesEvidenceWithoutChoosingParent() {
        var candidate = fixtureCandidate(label: "com.example.helper")
        candidate.configuration = LaunchdPlistParser().parse(dictionary: [
            "Label": "com.example.helper",
            "Program": "/Library/Application Support/Example/helper",
            "AssociatedBundleIdentifiers": ["com.example.parent"],
        ])
        let applications = ["/Applications/Parent.app", "/Volumes/External/Parent.app"].map { path in
            StartupInstalledApplication(
                bundleIdentifier: "com.example.parent",
                bundleURL: URL(fileURLWithPath: path),
                executableURL: nil,
                displayName: "Parent",
                developerName: "Example Developer",
                teamIdentifier: "TEAM123",
                codeSigningIdentifier: "com.example.parent",
                designatedRequirement: nil
            )
        }

        let resolved = StartupAttributionResolver().resolve(
            candidate,
            using: InstalledApplicationIndex(applications: applications)
        )

        XCTAssertEqual(resolved.attribution?.applicationBundleIdentifier, "com.example.parent")
        XCTAssertEqual(resolved.attribution?.confidence, .medium)
        XCTAssertNil(resolved.attribution?.applicationURL)
        XCTAssertNil(resolved.attribution?.applicationName)
        XCTAssertNil(resolved.attribution?.developerName)
        XCTAssertNil(resolved.applicationURL)
        XCTAssertNil(resolved.reliableApplicationIdentity)
        XCTAssertFalse(resolved.hasAuthoritativeParentApplication)
        XCTAssertTrue(resolved.attribution?.evidence.contains(where: {
            $0.kind == .associatedBundleIdentifier
                && $0.value == "com.example.parent"
                && $0.confidence == .medium
        }) == true)
    }

    func testEmbeddedExecutableUsesDeepestStandardizedApplicationPath() {
        let outerURL = URL(fileURLWithPath: "/Applications/Outer.app")
        let nestedURL = outerURL.appendingPathComponent(
            "Contents/Library/LoginItems/Nested.app"
        )
        let applications = [
            StartupInstalledApplication(
                bundleIdentifier: "com.example.outer",
                bundleURL: outerURL,
                executableURL: nil,
                displayName: "Outer",
                developerName: nil,
                teamIdentifier: nil,
                codeSigningIdentifier: nil,
                designatedRequirement: nil
            ),
            StartupInstalledApplication(
                bundleIdentifier: "com.example.nested",
                bundleURL: nestedURL,
                executableURL: nil,
                displayName: "Nested",
                developerName: nil,
                teamIdentifier: nil,
                codeSigningIdentifier: nil,
                designatedRequirement: nil
            ),
        ]
        var candidate = fixtureCandidate(label: "unrelated.helper")
        candidate.executableURL = nestedURL
            .appendingPathComponent("Contents/MacOS/../MacOS/Nested")

        let resolved = StartupAttributionResolver().resolve(
            candidate,
            using: InstalledApplicationIndex(applications: applications)
        )

        XCTAssertEqual(resolved.applicationURL, nestedURL)
        XCTAssertEqual(resolved.attribution?.confidence, .verified)
        XCTAssertEqual(resolved.attribution?.evidence.first?.kind, .embeddedInApplication)
    }

    func testBackgroundDiagnosticAuthorizationFailureIsExplicit() async {
        let runner = RecordingStartupRunner(responses: [
            StartupCommandResult(terminationStatus: 1, standardOutput: "", standardError: "errAuthorizationInvalidRef"),
        ])
        let scanner = BackgroundTaskManagementScanner(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: runner
        )
        do {
            _ = try await scanner.scan(context: StartupScanContext(
                applicationDirectories: [],
                includeBackgroundTaskDiagnostic: true
            ))
            XCTFail("Expected restricted diagnostic failure")
        } catch let error as BackgroundTaskManagementScanError {
            guard case let .restricted(message) = error else { return XCTFail("Unexpected error") }
            XCTAssertTrue(message.contains("errAuthorizationInvalidRef"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoginItemScannerPrefersStructuredSystemProfilerJSON() async throws {
        let runner = RecordingStartupRunner(responses: [
            StartupCommandResult(
                terminationStatus: 0,
                standardOutput: "{\"SPLoginItemDataType\":[{\"_name\":\"Example\",\"path\":\"/Applications/Example.app\"}]}",
                standardError: ""
            ),
        ])
        let scanner = LoginItemScanner(
            runner: runner,
            systemProfilerURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let candidates = try await scanner.scan(context: StartupScanContext(applicationDirectories: []))
        XCTAssertEqual(candidates.map(\.name), ["Example"])
        XCTAssertEqual(candidates[0].diagnosticEvidence, ["system-profiler-login-items", "structured-json"])
        let recordedArguments = await runner.recordedArguments()
        XCTAssertEqual(recordedArguments, [["SPLoginItemDataType", "-json"]])
    }

    func testLoginItemScannerDoesNotRequestSystemEventsForEmptyStructuredResult() async throws {
        let runner = RecordingStartupRunner(responses: [
            StartupCommandResult(
                terminationStatus: 0,
                standardOutput: "{\"SPLoginItemDataType\":[]}",
                standardError: ""
            ),
        ])
        let scanner = LoginItemScanner(
            runner: runner,
            systemProfilerURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        let candidates = try await scanner.scan(
            context: StartupScanContext(applicationDirectories: [])
        )

        XCTAssertTrue(candidates.isEmpty)
        let recordedArguments = await runner.recordedArguments()
        XCTAssertEqual(recordedArguments, [["SPLoginItemDataType", "-json"]])
    }

    func testRuntimePIDMissingIsLoadedStoppedNotDisabled() async throws {
        let runner = RecordingStartupRunner(responses: [
            StartupCommandResult(terminationStatus: 0, standardOutput: "PID\tStatus\tLabel\n-\t0\tcom.example.agent\n", standardError: ""),
            StartupCommandResult(terminationStatus: 0, standardOutput: "disabled services = {\n\"com.example.agent\" => false;\n}", standardError: ""),
            StartupCommandResult(terminationStatus: 0, standardOutput: "disabled services = {\n}", standardError: ""),
            StartupCommandResult(terminationStatus: 0, standardOutput: "gui/501/com.example.agent = {\nstate = not running\nruns = 2\n}", standardError: ""),
        ])
        let scanner = LaunchdRuntimeScanner(
            runner: runner,
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        var candidate = fixtureCandidate(label: "com.example.agent")
        candidate.state.enablement = .unknown
        let results = try await scanner.scan(context: StartupScanContext(
            applicationDirectories: [],
            seedCandidates: [candidate],
            currentUserID: 501
        ))
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.state.enablement, .enabled)
        XCTAssertEqual(result.state.load, .onDemand)
        XCTAssertEqual(result.state.process, .stopped)
    }

    func testRuntimeTreatsMissingOverrideAsEnabledOnlyAfterSuccessfulQuery() async throws {
        let successful = LaunchdRuntimeScanner(
            runner: RoutingStartupRunner(disabledQuerySucceeds: true),
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let failed = LaunchdRuntimeScanner(
            runner: RoutingStartupRunner(disabledQuerySucceeds: false),
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        var candidate = fixtureCandidate(label: "com.example.agent")
        candidate.state.enablement = .unknown
        let context = StartupScanContext(
            applicationDirectories: [],
            seedCandidates: [candidate],
            currentUserID: 501
        )

        let successfulResults = try await successful.scan(context: context)
        let failedResults = try await failed.scan(context: context)
        let successfulResult = try XCTUnwrap(successfulResults.first)
        let failedResult = try XCTUnwrap(failedResults.first)
        XCTAssertEqual(successfulResult.state.enablement, .enabled)
        XCTAssertEqual(failedResult.state.enablement, .unknown)
    }

    func testRuntimePreservesPlistDisabledDefaultWhenThereIsNoOverride() async throws {
        let scanner = LaunchdRuntimeScanner(
            runner: RoutingStartupRunner(disabledQuerySucceeds: true),
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        var candidate = fixtureCandidate(label: "com.example.disabled")
        candidate.configuration = LaunchdPlistParser().parse(dictionary: [
            "Label": "com.example.disabled",
            "Program": "/usr/bin/true",
            "Disabled": true,
        ])
        candidate.state.enablement = .disabled

        let results = try await scanner.scan(context: StartupScanContext(
            applicationDirectories: [],
            seedCandidates: [candidate],
            currentUserID: 501
        ))
        let result = try XCTUnwrap(results.first)

        XCTAssertEqual(result.state.enablement, .disabled)
    }

    func testPrivilegedHelperRequiresExistingStartupEvidence() async throws {
        let directory = URL(fileURLWithPath: "/Library/PrivilegedHelperTools")
        let scanner = PrivilegedHelperScanner(directory: directory)
        var matching = fixtureCandidate(label: "com.example.helper")
        matching.executableURL = directory.appendingPathComponent("com.example.helper")
        let unrelated = try await scanner.scan(context: StartupScanContext(applicationDirectories: []))
        let matched = try await scanner.scan(context: StartupScanContext(
            applicationDirectories: [], seedCandidates: [matching]
        ))
        XCTAssertTrue(unrelated.isEmpty)
        XCTAssertEqual(matched.count, 1)
        XCTAssertTrue(matched[0].actionCapability.requiresAdministrator)
    }

    func testUnmountedExternalVolumeIsNotMarkedOrphaned() async throws {
        var candidate = fixtureCandidate(label: "com.example.external")
        candidate.plistURL = URL(fileURLWithPath: "/tmp/com.example.external.plist")
        candidate.executableURL = URL(fileURLWithPath: "/Volumes/DefinitelyUnmounted/App.app/Contents/MacOS/App")
        let results = try await OrphanedItemScanner().scan(context: StartupScanContext(
            applicationDirectories: [], seedCandidates: [candidate]
        ))
        XCTAssertTrue(results.isEmpty)
    }

    func testDeduplicatorMergesRuntimeAndBTMEvidenceButPreservesDuplicatePlistPaths() {
        var first = fixtureCandidate(label: "com.example.agent", id: "first")
        first.plistURL = URL(fileURLWithPath: "/one/com.example.agent.plist")
        first.executableURL = URL(fileURLWithPath: "/Applications/Example.app/Contents/MacOS/helper")
        var duplicate = fixtureCandidate(label: "com.example.agent", id: "second")
        duplicate.plistURL = URL(fileURLWithPath: "/two/com.example.agent.plist")
        duplicate.executableURL = first.executableURL
        var runtime = fixtureCandidate(label: "com.example.agent", id: "runtime:com.example.agent")
        runtime.source = .launchdRuntime
        runtime.plistURL = nil
        runtime.executableURL = first.executableURL
        runtime.state.process = .running(pid: 42)

        let deduplicated = StartupItemDeduplicator().deduplicate([first, duplicate, runtime])
        XCTAssertEqual(deduplicated.count, 2)
        XCTAssertTrue(deduplicated.allSatisfy { $0.state.process == .running(pid: 42) })
        let items = StartupItemMerger().merge(deduplicated)
        XCTAssertTrue(items.flatMap(\.warnings).contains("duplicate-label:com.example.agent"))
    }

    func testDeduplicatorMergesManagementStateFailClosedRegardlessOfSourceOrder() {
        var direct = fixtureCandidate(label: "com.example.agent", id: "same")
        direct.state.management = .directlyManageable
        var protected = fixtureCandidate(label: "com.example.agent", id: "same")
        protected.state.management = .systemProtected

        let directThenProtected = StartupItemDeduplicator().deduplicate([direct, protected])
        let protectedThenDirect = StartupItemDeduplicator().deduplicate([protected, direct])

        XCTAssertEqual(directThenProtected.count, 1)
        XCTAssertEqual(protectedThenDirect.count, 1)
        XCTAssertEqual(directThenProtected.first?.state.management, .systemProtected)
        XCTAssertEqual(protectedThenDirect.first?.state.management, .systemProtected)
    }

    func testMergerRequiresHighConfidenceApplicationEvidence() {
        var first = fixtureCandidate(label: "com.example.first", id: "first")
        var second = fixtureCandidate(label: "com.example.second", id: "second")
        first.attribution = fixtureAttribution(confidence: .low)
        second.attribution = fixtureAttribution(confidence: .low)
        first.applicationURL = URL(fileURLWithPath: "/Applications/Example.app")
        second.applicationURL = first.applicationURL

        XCTAssertEqual(StartupItemMerger().merge([first, second]).count, 2)

        first.attribution = fixtureAttribution(confidence: .high)
        second.attribution = fixtureAttribution(confidence: .verified)
        let merged = StartupItemMerger().merge([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].components.count, 2)
    }

    func testMergerKeepsSameBundleIdentifierFromDifferentTeamsSeparate() {
        var first = fixtureCandidate(label: "com.example.first", id: "first")
        var second = fixtureCandidate(label: "com.example.second", id: "second")
        first.attribution = fixtureAttribution(confidence: .verified)
        second.attribution = fixtureAttribution(confidence: .verified)
        first.attribution?.teamIdentifier = "TEAMAAAAAA"
        second.attribution?.teamIdentifier = "TEAMBBBBBB"

        XCTAssertEqual(StartupItemMerger().merge([first, second]).count, 2)

        second.attribution?.teamIdentifier = "TEAMAAAAAA"
        let merged = StartupItemMerger().merge([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].components.count, 2)
    }

    func testTrustAssessmentUsesEvidenceRatherThanName() {
        var candidate = fixtureCandidate(label: "com.apple.lookalike")
        candidate.diagnosticEvidence = ["valid-code-signature"]
        XCTAssertEqual(candidate.trustAssessment, .verifiedDeveloper)
        XCTAssertFalse(candidate.isVerifiedAppleSystem)

        candidate.diagnosticEvidence.append("team-identifier-mismatch")
        XCTAssertEqual(candidate.trustAssessment, .invalidSignature)
    }

    func testPurposeResolverRecognizesOnlyVerifiedGoogleKeystoneIdentity() {
        var google = fixtureCandidate(label: "com.google.keystone.agent")
        google.attribution = purposeAttribution(
            bundleIdentifier: "com.google.Chrome",
            teamIdentifier: "EQHXZ8M8AV",
            confidence: .high
        )
        google.diagnosticEvidence = ["valid-code-signature"]

        let purpose = google.resolvedPurpose
        XCTAssertEqual(purpose.source, .verifiedRegistry)
        XCTAssertEqual(purpose.confidence, .verified)
        XCTAssertEqual(
            purpose.value,
            L10n.text("检查并安装 Google 应用更新", "Checks and installs Google application updates")
        )

        google.attribution?.evidence = [
            .init(kind: .labelHint, value: "Google", confidence: .low),
        ]
        XCTAssertNotEqual(google.resolvedPurpose.source, .verifiedRegistry)
    }

    func testPurposeResolverRecognizesOnlyVerifiedMicrosoftAutoUpdateIdentity() {
        var microsoft = fixtureCandidate(label: "com.microsoft.update.agent")
        microsoft.attribution = purposeAttribution(
            bundleIdentifier: "com.microsoft.autoupdate2",
            teamIdentifier: "UBF8T346G9",
            confidence: .verified
        )
        microsoft.diagnosticEvidence = ["valid-code-signature"]

        let purpose = microsoft.resolvedPurpose
        XCTAssertEqual(purpose.source, .verifiedRegistry)
        XCTAssertEqual(purpose.confidence, .verified)
        XCTAssertEqual(
            purpose.value,
            L10n.text("检查并安装 Microsoft 应用更新", "Checks and installs Microsoft application updates")
        )
    }

    func testPurposeResolverMarksUnknownBackgroundPurposeAsConfigurationInference() {
        var unknown = fixtureCandidate(label: "com.example.unknown")
        unknown.kind = .appBackgroundTask
        unknown.configuration = nil

        let purpose = unknown.resolvedPurpose
        XCTAssertEqual(purpose.source, .launchConfigurationInference)
        XCTAssertEqual(purpose.confidence, .low)
        XCTAssertEqual(
            purpose.value,
            L10n.text(
                "登录后按需运行；具体用途尚未确认",
                "Runs on demand after login; specific purpose is not yet confirmed"
            )
        )
    }

    func testAppleSystemSignatureEvidenceClassifiesBTMButNotDeveloperIDAnchor() {
        var candidate = fixtureCandidate(label: "com.apple.background")
        candidate.source = .backgroundTaskDiagnostic
        candidate.kind = .appBackgroundTask
        candidate.scope = .currentUser
        candidate.diagnosticEvidence = ["valid-code-signature", "apple-system-signature"]

        XCTAssertTrue(candidate.isVerifiedAppleSystem)
        XCTAssertTrue(StartupItemsDomain.Candidate.isAppleSystemDesignatedRequirement("identifier x and anchor apple"))
        XCTAssertFalse(StartupItemsDomain.Candidate.isAppleSystemDesignatedRequirement(
            "identifier x and anchor apple generic and certificate leaf"
        ))
        let destination = StartupItemsDomain.StartupCapabilityResolver(
            platform: .nonSandboxDirect,
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        ).destination(for: candidate)
        XCTAssertEqual(destination, .systemProtected)
    }

    func testDotSegmentPathStillClassifiesProtectedSystemApplication() {
        var candidate = fixtureCandidate(label: "com.apple.Maps")
        candidate.applicationURL = URL(
            fileURLWithPath: "/Applications/../System/Applications/Maps.app"
        )

        XCTAssertTrue(candidate.isVerifiedAppleSystem)
    }

    func testAppleLaunchdItemRemainsAppleWhenMergedWithOrphanCompanion() async throws {
        var apple = fixtureCandidate(label: "com.apple.missing", id: "apple-source")
        apple.kind = .systemLaunchAgent
        apple.scope = .system
        apple.plistURL = URL(fileURLWithPath: "/System/Library/LaunchAgents/com.apple.missing.plist")
        apple.executableURL = URL(fileURLWithPath: "/System/Library/DefinitelyMissingStorageCleanerFixture")
        apple.diagnosticEvidence = ["apple-system-location", "target-missing"]

        let companions = try await OrphanedItemScanner().scan(context: StartupScanContext(
            applicationDirectories: [],
            seedCandidates: [apple]
        ))
        let companion = try XCTUnwrap(companions.first)
        let merged = StartupItemMerger().merge([apple, companion])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].components.count, 2)
        XCTAssertTrue(merged[0].isAppleSystem)
        XCTAssertTrue(merged[0].isOrphaned)
    }

    func testMissingExecutableDeclarationDoesNotBecomeOrphan() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plistURL = root.appendingPathComponent("com.example.unresolved.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.unresolved"],
            format: .xml,
            options: 0
        ).write(to: plistURL)
        let candidates = try await LaunchdPlistScanner(
            location: .custom(directory: root, kind: .userLaunchAgent, scope: .currentUser)
        ).scan(context: StartupScanContext(applicationDirectories: []))
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertNil(candidate.executableURL)
        XCTAssertTrue(candidate.diagnosticEvidence.contains("missing-executable"))
        XCTAssertFalse(candidate.diagnosticEvidence.contains("target-missing"))
        let orphans = try await OrphanedItemScanner().scan(context: StartupScanContext(
            applicationDirectories: [],
            seedCandidates: [candidate]
        ))
        XCTAssertTrue(orphans.isEmpty)
    }

    func testCoordinatorKeepsOtherSourcesWhenOneFailsAndReportsCoverage() async throws {
        let good = FixedStartupScanner(
            source: .launchdPlist,
            identifier: "good",
            outcome: .success([fixtureCandidate(label: "com.example.agent")])
        )
        let bad = FixedStartupScanner(
            source: .backgroundTaskDiagnostic,
            identifier: "restricted",
            outcome: .failure("authorization denied")
        )
        let coordinator = StartupScanCoordinator(
            primaryScanners: [good, bad],
            secondaryScannerFactory: { _ in [] }
        )
        let result = try await coordinator.scan(context: StartupScanContext(applicationDirectories: []))
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.coverage.sources.count, 2)
        XCTAssertEqual(result.coverage.sources.first { $0.identifier == "restricted" }?.errorDescription, "authorization denied")
        XCTAssertEqual(result.coverage.rawEvidenceCount, 1)
        XCTAssertEqual(result.coverage.filteredEvidenceCount, 0)
        XCTAssertEqual(result.coverage.discoveredBeforeDeduplication, 1)
        XCTAssertEqual(result.coverage.candidatesAfterDeduplication, 1)
        XCTAssertFalse(result.coverage.managedItemCoverageAvailable)
        XCTAssertNil(result.coverage.managedItemCount)
    }

    func testCoordinatorTreatsUnsafePlistPermissionsAsManagementAndAttentionEvidence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let launchAgents = root.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plistURL = launchAgents.appendingPathComponent("com.example.unsafe.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.unsafe", "Program": "/usr/bin/true"],
            format: .xml,
            options: 0
        ).write(to: plistURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: plistURL.path)

        var candidate = fixtureCandidate(label: "com.example.unsafe")
        candidate.plistURL = plistURL
        candidate.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        candidate.attribution = StartupItemsDomain.Attribution(
            applicationBundleIdentifier: "com.example.unsafe",
            applicationURL: URL(fileURLWithPath: "/usr/bin/true"),
            applicationName: "Unsafe Fixture",
            developerName: "Fixture",
            teamIdentifier: nil,
            designatedRequirement: nil,
            evidence: [.init(kind: .backgroundTaskManagement, value: "fixture", confidence: .verified)]
        )
        let coordinator = StartupScanCoordinator(
            primaryScanners: [FixedStartupScanner(
                source: .launchdPlist,
                identifier: "unsafe-plist",
                outcome: .success([candidate])
            )],
            secondaryScannerFactory: { _ in [] },
            managementCapability: .nonSandboxDirect
        )

        let result = try await coordinator.scan(context: StartupScanContext(
            homeDirectory: root,
            applicationDirectories: []
        ))
        let scanned = try XCTUnwrap(result.candidates.first)
        XCTAssertTrue(scanned.diagnosticEvidence.contains("group-writable"))
        XCTAssertTrue(scanned.diagnosticEvidence.contains("world-writable"))
        XCTAssertFalse(scanned.diagnosticEvidence.contains("plist-world-writable"))
        XCTAssertFalse(scanned.actionCapability.canDisableDirectly)
        XCTAssertTrue(try XCTUnwrap(result.items.first).needsAttention)
    }

    func testCoordinatorDoesNotTreatAValidPlistAsANonExecutableTarget() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let launchAgents = root.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plistURL = launchAgents.appendingPathComponent("com.example.verified.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.verified", "Program": "/usr/bin/true"],
            format: .xml,
            options: 0
        ).write(to: plistURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)

        var candidate = fixtureCandidate(label: "com.example.verified")
        candidate.plistURL = plistURL
        candidate.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        candidate.applicationURL = nil
        candidate.attribution = nil
        let coordinator = StartupScanCoordinator(
            primaryScanners: [FixedStartupScanner(
                source: .launchdPlist,
                identifier: "verified-plist",
                outcome: .success([candidate])
            )],
            secondaryScannerFactory: { _ in [] },
            managementCapability: .nonSandboxDirect
        )

        let result = try await coordinator.scan(context: StartupScanContext(
            homeDirectory: root,
            applicationDirectories: []
        ))
        let scanned = try XCTUnwrap(result.candidates.first)
        XCTAssertFalse(scanned.diagnosticEvidence.contains("target-not-executable"))
        XCTAssertTrue(scanned.diagnosticEvidence.contains("valid-code-signature"))
        XCTAssertTrue(scanned.actionCapability.canEnableDirectly)
        XCTAssertTrue(scanned.actionCapability.canDisableDirectly)
        XCTAssertEqual(scanned.state.management, .directlyManageable)
    }

    func testCoverageUsesVisibleComponentPopulationAndExplicitAvailability() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let launchAgents = root.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plistURL = launchAgents.appendingPathComponent("com.example.direct.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.direct", "Program": "/usr/bin/true"],
            format: .xml,
            options: 0
        ).write(to: plistURL)

        var direct = fixtureCandidate(label: "com.example.direct", id: "direct")
        direct.plistURL = plistURL
        direct.state.process = .running(pid: 42)
        direct.attribution = StartupItemsDomain.Attribution(
            applicationBundleIdentifier: "com.example.app",
            applicationURL: root.appendingPathComponent("Example.app"),
            applicationName: "Example",
            developerName: "Example",
            teamIdentifier: "TEAM123",
            designatedRequirement: nil,
            evidence: [.init(kind: .associatedBundleIdentifier, value: "com.example.app", confidence: .high)]
        )
        direct.diagnosticEvidence = ["valid-code-signature"]

        var login = fixtureCandidate(label: "com.example.login", id: "login")
        login.kind = .loginItem
        login.source = .serviceManagement

        var managed = fixtureCandidate(label: "com.example.managed", id: "managed")
        managed.kind = .managedItem
        managed.scope = .managed
        managed.source = .backgroundTaskDiagnostic
        managed.state.authorization = .managed

        var daemon = fixtureCandidate(label: "com.example.daemon", id: "daemon")
        daemon.kind = .launchDaemon
        daemon.scope = .allUsers

        var apple = fixtureCandidate(label: "com.apple.fixture", id: "apple")
        apple.kind = .systemLaunchAgent
        apple.scope = .system
        apple.plistURL = URL(fileURLWithPath: "/System/Library/LaunchAgents/com.apple.fixture.plist")
        apple.diagnosticEvidence = ["apple-system-location"]

        var openAtLogin = fixtureCandidate(label: "com.example.open", id: "open")
        openAtLogin.kind = .openAtLogin
        openAtLogin.source = .openAtLogin

        var hidden = fixtureCandidate(label: "com.example.unregistered", id: "hidden")
        hidden.source = .embeddedService
        hidden.kind = .embeddedHelper
        hidden.state.registration = .notRegistered

        let coordinator = StartupScanCoordinator(
            primaryScanners: [
                FixedStartupScanner(
                    source: .launchdPlist,
                    identifier: "fixture-primary",
                    outcome: .success([direct, login, daemon, apple, openAtLogin])
                ),
                FixedStartupScanner(
                    source: .backgroundTaskDiagnostic,
                    identifier: "fixture-btm",
                    outcome: .success([managed])
                ),
                FixedStartupScanner(
                    source: .embeddedService,
                    identifier: "fixture-embedded",
                    outcome: .success([hidden])
                ),
            ],
            secondaryScannerFactory: { _ in [] },
            managementCapability: .nonSandboxDirect
        )
        let result = try await coordinator.scan(context: StartupScanContext(
            homeDirectory: root,
            applicationDirectories: [],
            includeBackgroundTaskDiagnostic: true
        ))

        XCTAssertEqual(result.coverage.rawEvidenceCount, 7)
        XCTAssertEqual(result.coverage.filteredEvidenceCount, 1)
        XCTAssertEqual(result.coverage.discoveredBeforeDeduplication, 6)
        XCTAssertEqual(result.coverage.candidatesAfterDeduplication, 6)
        XCTAssertEqual(result.coverage.openAtLoginCount, 2)
        XCTAssertEqual(result.coverage.runningCount, 1)
        XCTAssertEqual(result.coverage.appleSystemCount, 1)
        XCTAssertEqual(result.coverage.systemProtectedItemCount, 1)
        XCTAssertEqual(
            result.coverage.attributedItemCount
                + result.coverage.systemProtectedItemCount
                + result.coverage.unattributedThirdPartyCount,
            result.coverage.groupedItemCount
        )
        XCTAssertTrue(result.coverage.managedItemCoverageAvailable)
        XCTAssertEqual(result.coverage.managedItemCount, 1)
        XCTAssertEqual(result.coverage.directlyManageableCount, 1)
        XCTAssertEqual(result.coverage.systemSettingsOnlyCount, 3)
        XCTAssertEqual(result.coverage.administratorRequiredCount, 1)
    }

    func testCoveragePartitions934MixedItemsWithoutTreatingAppleAsUnattributedThirdParty() async throws {
        let appleCandidates = (0..<919).map { index -> StartupItemsDomain.Candidate in
            var candidate = fixtureCandidate(
                label: "com.apple.fixture.\(index)",
                id: "apple-fixture-\(index)"
            )
            candidate.source = .backgroundTaskDiagnostic
            candidate.kind = .appBackgroundTask
            candidate.scope = .system
            candidate.diagnosticEvidence = ["apple-system-signature"]
            return candidate
        }
        let attributedThirdPartyCandidates = (0..<13).map { index -> StartupItemsDomain.Candidate in
            var candidate = fixtureCandidate(
                label: "com.example.attributed.\(index)",
                id: "attributed-fixture-\(index)"
            )
            let bundleIdentifier = "com.example.application.\(index)"
            candidate.attribution = StartupItemsDomain.Attribution(
                applicationBundleIdentifier: bundleIdentifier,
                applicationURL: URL(fileURLWithPath: "/Applications/Fixture\(index).app"),
                applicationName: "Fixture \(index)",
                developerName: "Example Corp",
                teamIdentifier: "TEAM123",
                designatedRequirement: nil,
                evidence: [
                    .init(
                        kind: .associatedBundleIdentifier,
                        value: bundleIdentifier,
                        confidence: .high
                    ),
                ]
            )
            return candidate
        }
        let unknownThirdPartyCandidates = (0..<2).map { index -> StartupItemsDomain.Candidate in
            var candidate = fixtureCandidate(
                label: "org.unknown.fixture.\(index)",
                id: "unknown-fixture-\(index)"
            )
            candidate.state.management = .unsupported
            candidate.actionCapability = .readOnly
            return candidate
        }
        let fixtures = appleCandidates
            + attributedThirdPartyCandidates
            + unknownThirdPartyCandidates
        let coordinator = StartupScanCoordinator(
            primaryScanners: [FixedStartupScanner(
                source: .backgroundTaskDiagnostic,
                identifier: "mixed-934-fixture",
                outcome: .success(fixtures)
            )],
            secondaryScannerFactory: { _ in [] }
        )

        let result = try await coordinator.scan(context: StartupScanContext(
            applicationDirectories: [],
            includeAppleSystemItems: true
        ))

        XCTAssertEqual(result.coverage.groupedItemCount, 934)
        XCTAssertEqual(result.coverage.systemProtectedItemCount, 919)
        XCTAssertEqual(result.coverage.attributedItemCount, 13)
        XCTAssertEqual(result.coverage.unattributedThirdPartyCount, 2)
        XCTAssertEqual(
            result.coverage.attributedItemCount
                + result.coverage.systemProtectedItemCount
                + result.coverage.unattributedThirdPartyCount,
            934
        )
        XCTAssertEqual(result.coverage.appleSystemCount, 919)
    }

    func testCoordinatorPropagatesExplicitCancellation() async {
        let coordinator = StartupScanCoordinator(
            primaryScanners: [SlowStartupScanner()],
            secondaryScannerFactory: { _ in [] }
        )
        let task = Task {
            try await coordinator.scan(context: StartupScanContext(applicationDirectories: []))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not be converted into an empty partial result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLiveReadOnlyCoverageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["STORAGE_CLEANER_RUN_LIVE_STARTUP_SCAN"] == "1" else {
            throw XCTSkip("Set STORAGE_CLEANER_RUN_LIVE_STARTUP_SCAN=1 for the read-only host coverage audit")
        }
        let result = try await StartupScanCoordinator().scan(context: StartupScanContext(
            includeAppleSystemItems: true,
            includeBackgroundTaskDiagnostic: true,
            // Match the explicit Full Scan timeout used by ScanStore. A large
            // BTM database can legitimately take longer than a normal command.
            commandTimeout: 60
        ))
        let sourceCounts = Dictionary(uniqueKeysWithValues: result.coverage.sources.map {
            ($0.identifier, $0.discoveredCount)
        })
        let sourceFailures = Dictionary(uniqueKeysWithValues: result.coverage.sources.compactMap { source -> (String, String)? in
            source.errorDescription.map { (source.identifier, $0) }
        })
        let kindCounts = Dictionary(uniqueKeysWithValues: result.coverage.countsByKind.map {
            ($0.key.rawValue, $0.value)
        })
        let payload: [String: Any] = [
            "rawEvidence": result.coverage.rawEvidenceCount,
            "filteredEvidence": result.coverage.filteredEvidenceCount,
            "beforeDeduplication": result.coverage.discoveredBeforeDeduplication,
            "afterDeduplication": result.coverage.candidatesAfterDeduplication,
            "grouped": result.coverage.groupedItemCount,
            "attributed": result.coverage.attributedItemCount,
            "systemProtectedItems": result.coverage.systemProtectedItemCount,
            "unattributedThirdParty": result.coverage.unattributedThirdPartyCount,
            "orphaned": result.coverage.orphanedCount,
            "directlyManageable": result.coverage.directlyManageableCount,
            "systemSettingsOnly": result.coverage.systemSettingsOnlyCount,
            "administratorRequired": result.coverage.administratorRequiredCount,
            "openAtLogin": result.coverage.openAtLoginCount,
            "running": result.coverage.runningCount,
            "appleSystem": result.coverage.appleSystemCount,
            "managedCoverageAvailable": result.coverage.managedItemCoverageAvailable,
            "managed": result.coverage.managedItemCount ?? NSNull(),
            "sources": sourceCounts,
            "sourceFailures": sourceFailures,
            "kinds": kindCounts,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print("LIVE_STARTUP_COVERAGE \(String(decoding: data, as: UTF8.self))")
        XCTAssertGreaterThan(result.coverage.candidatesAfterDeduplication, 0)
    }

    private func temporaryDirectory() throws -> URL {
        let URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StartupScanningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: URL, withIntermediateDirectories: true)
        return URL
    }

    @MainActor
    private func waitForStartupScan(_ store: ScanStore) async throws {
        for _ in 0..<200 {
            if !store.isLoadingStartupItems { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Startup scan did not finish within the test deadline")
    }
}

private actor RecordingStartupRunner: StartupCommandRunning {
    private var responses: [StartupCommandResult]
    private var arguments = [[String]]()
    private var timeouts = [TimeInterval]()

    init(responses: [StartupCommandResult]) {
        self.responses = responses
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> StartupCommandResult {
        self.arguments.append(arguments)
        self.timeouts.append(timeout)
        guard !responses.isEmpty else {
            return StartupCommandResult(terminationStatus: 1, standardOutput: "", standardError: "no fixture")
        }
        return responses.removeFirst()
    }

    func recordedArguments() -> [[String]] { arguments }

    func recordedTimeouts() -> [TimeInterval] { timeouts }
}

private struct FixedStartupScanner: StartupItemScanning {
    enum Outcome: Sendable {
        case success([StartupItemsDomain.Candidate])
        case failure(String)
    }

    let source: StartupItemsDomain.ScanSource
    let identifier: String
    let outcome: Outcome
    var coverageIdentifier: String { identifier }

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate] {
        switch outcome {
        case let .success(candidates): candidates
        case let .failure(message): throw FixtureError(message: message)
        }
    }

    struct FixtureError: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }
}

private struct SlowStartupScanner: StartupItemScanning {
    let source = StartupItemsDomain.ScanSource.launchdPlist
    let coverageIdentifier = "slow-cancellable"

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate] {
        try await Task.sleep(for: .seconds(5))
        return []
    }
}

private struct RoutingStartupRunner: StartupCommandRunning {
    let disabledQuerySucceeds: Bool

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> StartupCommandResult {
        if arguments == ["list"] {
            return StartupCommandResult(terminationStatus: 0, standardOutput: "", standardError: "")
        }
        if arguments.first == "print-disabled" {
            return StartupCommandResult(
                terminationStatus: disabledQuerySucceeds ? 0 : 1,
                standardOutput: disabledQuerySucceeds ? "disabled services = { }" : "",
                standardError: disabledQuerySucceeds ? "" : "restricted"
            )
        }
        if arguments.first == "print" {
            return StartupCommandResult(
                terminationStatus: 1,
                standardOutput: "",
                standardError: "Could not find service"
            )
        }
        return StartupCommandResult(terminationStatus: 1, standardOutput: "", standardError: "unexpected")
    }
}

private func fixtureCandidate(label: String, id: String? = nil) -> StartupItemsDomain.Candidate {
    StartupItemsDomain.Candidate(
        id: id ?? "fixture:\(label)",
        source: .launchdPlist,
        kind: .userLaunchAgent,
        scope: .currentUser,
        name: label,
        label: label,
        plistURL: nil,
        executableURL: nil,
        applicationURL: nil,
        configuration: nil,
        state: StartupItemsDomain.State(
            registration: .discoveredFromFile,
            authorization: .unknown,
            enablement: .enabled,
            load: .unknown,
            process: .unknown,
            management: .directlyManageable
        ),
        attribution: nil,
        actionCapability: StartupItemsDomain.ActionCapability(
            canEnableDirectly: true,
            canDisableDirectly: true,
            canStopCurrentSession: true,
            canOpenSystemSettings: true,
            canRevealInFinder: true,
            canOpenParentApp: false,
            canRemoveOrphan: false,
            requiresAdministrator: false,
            isReadOnly: false,
            isManaged: false
        ),
        diagnosticEvidence: []
    )
}

private func fixtureAttribution(
    confidence: StartupItemsDomain.AttributionConfidence
) -> StartupItemsDomain.Attribution {
    StartupItemsDomain.Attribution(
        applicationBundleIdentifier: "com.example.app",
        applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
        applicationName: "Example",
        developerName: "Example Corp",
        teamIdentifier: "TEAM123",
        designatedRequirement: nil,
        evidence: [
            .init(kind: .labelHint, value: "example", confidence: confidence),
        ]
    )
}

private func purposeAttribution(
    bundleIdentifier: String,
    teamIdentifier: String,
    confidence: StartupItemsDomain.AttributionConfidence
) -> StartupItemsDomain.Attribution {
    StartupItemsDomain.Attribution(
        applicationBundleIdentifier: bundleIdentifier,
        applicationURL: nil,
        applicationName: nil,
        developerName: nil,
        teamIdentifier: teamIdentifier,
        designatedRequirement: nil,
        evidence: [
            .init(kind: .associatedBundleIdentifier, value: bundleIdentifier, confidence: confidence),
        ]
    )
}
