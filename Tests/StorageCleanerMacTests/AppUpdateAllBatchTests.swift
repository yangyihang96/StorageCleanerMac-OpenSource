import CryptoKit
import FileOperationShared
import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateAllBatchTests: XCTestCase {
    func testGreedyFontAndFormulaShareAutomaticPlanAndNeverWebsiteQueue() async throws {
        let provider = HomebrewProvider(homebrewExecutableProvider: { URL(fileURLWithPath: "/fake/brew") })
        let inputs = [package("font-hack", kind: .cask), package("gemini-cli", kind: .formula), package("raycast", kind: .cask, greedy: true)]
        var apps = [InstalledApplication]()
        for input in inputs { apps.append(await ApplicationUpdateProviderRegistry(providers: [provider]).classify(input)) }
        XCTAssertTrue(apps.allSatisfy(\.canAutomaticallyUpdate))
        let plan = FrozenUpdatePlan(applications: apps)
        XCTAssertEqual(Set(plan.executionPlan.batchApplicationIDs), Set(inputs.map(\.id)))
        XCTAssertEqual(plan.executionPlan.batchCount, 3)
        XCTAssertTrue(plan.plan.websiteApplicationIDs.isEmpty)
        XCTAssertTrue(AppUpdateService.oneClickPlan(for: apps).guidedWebsiteApps.isEmpty)
        XCTAssertEqual(HomebrewUpdateRecipeBuilder.arguments(for: apps[2]), ["upgrade", "--cask", "--greedy", "raycast"])
    }

    func testPinnedDisabledDeprecatedAndSystemAppsAreExcludedAndExplained() async throws {
        let provider = HomebrewProvider(homebrewExecutableProvider: { URL(fileURLWithPath: "/fake/brew") })
        var apps = [InstalledApplication]()
        for flag in ["pinned", "disabled", "deprecated"] {
            var app = package(flag, kind: .formula)
            app.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(token: flag, kind: .formula,
                isPinned: flag == "pinned", isDisabled: flag == "disabled", isDeprecated: flag == "deprecated", appBundlePaths: [])
            app = await ApplicationUpdateProviderRegistry(providers: [provider]).classify(app)
            XCTAssertFalse(app.canJoinAutomaticUpdateBatch)
            XCTAssertFalse(app.canAutomaticallyUpdate)
            XCTAssertNotNil(app.updateError)
            apps.append(app)
        }
        var system = package("system", kind: .formula)
        system.isSystemApplication = true; system.updateProvider = .systemManaged
        apps.append(system)
        XCTAssertEqual(AppUpdateBatchPresentation(applications: apps).count, 0)
    }

    func testHomebrewMergesKindsAndGreedyFlagAndReadsBackEveryVersion() async throws {
        let state = BatchTestState()
        let inputs = [package("font-a", kind: .cask), package("font-b", kind: .cask, greedy: true), package("cli", kind: .formula)]
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: BatchTestCommandRunner(state: state),
            runtime: runtime(state), environment: { [:] }, captureExecutable: appUpdateFixtureExecutable)
        let results = await installer.install(applications: inputs) { _ in }
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.state == .completed && $0.observedVersion?.marketing == "2.0" })
        let calls = await state.commands
        XCTAssertEqual(calls.filter { $0.first == "upgrade" }, [["upgrade", "--formula", "cli"], ["upgrade", "--cask", "--greedy", "font-a", "font-b"]])
        XCTAssertEqual(calls.filter { $0.first == "list" }.count, 6)
    }
    func testSymbolicLatestVariantsStayPendingAcrossVerifyReconcileAndRetryGate() async throws {
        for symbolic in [":latest", "LATEST", ":LaTeSt"] {
            let state = BatchTestState()
            var app = package("symbolic-tool", kind: .cask)
            app.homebrewMetadata = .init(token: "symbolic-tool", kind: .cask, homepageURL: nil, installedVersions: [symbolic], currentVersion: symbolic,
                isOutdated: true, outdatedProvenance: .greedy, isPinned: false, isDisabled: false, isDeprecated: false, autoUpdates: true,
                requiresManualInstaller: false, appBundlePaths: [])
            let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: SymbolicVariantRunner(symbolic: symbolic),
                runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
            let results = await installer.install(applications: [app]) { _ in }
            XCTAssertEqual(results.first?.state, .needsReconciliation, symbolic)
            let task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
            let reconciled = try await installer.reconcile(application: app, task: task)
            XCTAssertEqual(reconciled.state, .needsReconciliation, symbolic)
        }
    }
    func testBrewSourceChangeBetweenInventoryAndUpgradeRejectsGroupWithoutInstallation() async throws {
        let state = BatchTestState()
        let identity = BatchExecutableChangeProbe()
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: BatchTestCommandRunner(state: state),
            runtime: runtime(state), captureExecutable: { try identity.capture($0) })
        let results = await installer.install(applications: [package("a", kind: .formula), package("b", kind: .formula)]) {
            if $0.state == .installing { identity.change() }
        }
        XCTAssertTrue(results.allSatisfy { $0.state == .failed && $0.detail.contains("/fake/brew") })
        let calls = await state.commands
        XCTAssertFalse(calls.contains(where: { $0.first == "upgrade" }))
    }
    func testAdministratorBrewRevokesTimestampImmediatelyEvenAfterInstallFailure() async throws {
        let state = BatchTestState(); await state.failToken("bad")
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: BatchTestCommandRunner(state: state), runtime: runtime(state),
            administratorEnvironment: ["SUDO_ASKPASS": "/sealed/fake"], captureExecutable: appUpdateFixtureExecutable,
            revokeAuthorization: { await state.event("revoke-sudo") })
        var app = package("bad", kind: .cask); app.requiresAdministratorAuthorization = true
        _ = await installer.install(applications: [app]) { _ in }
        let events = await state.events
        XCTAssertEqual(events.filter { $0 == "revoke-sudo" }.count, 1)
    }

    func testFailedBrewTokenDoesNotBlockLaterTokensAndOnlyUntouchedTokensRetry() async throws {
        let state = BatchTestState(); await state.failToken("bad")
        let inputs = [package("first", kind: .cask), package("bad", kind: .cask), package("after", kind: .cask)]
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: BatchTestCommandRunner(state: state), runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
        let results = await installer.install(applications: inputs) { _ in }
        XCTAssertEqual(results.first(where: { $0.applicationID == "first" })?.state, .completed)
        XCTAssertEqual(results.first(where: { $0.applicationID == "bad" })?.state, .failed)
        XCTAssertEqual(results.first(where: { $0.applicationID == "after" })?.state, .completed)
        let calls = await state.commands.filter { $0.first == "upgrade" }
        XCTAssertEqual(calls.count, 3)
        XCTAssertFalse(calls.dropFirst().contains { $0.contains("first") })
    }

    func testRunningApplicationQuitsUpdatesReopensAndRefusalDoesNotBlockNext() async throws {
        let state = BatchTestState(); await state.setRunning(["running", "refuses"]); await state.setRefuses(["refuses"])
        var apps = [package("running", kind: .cask), package("refuses", kind: .cask), package("after", kind: .formula)]
        for index in 0..<2 { apps[index].packageKind = .graphicalApplication; apps[index].homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(token: apps[index].id, appBundlePaths: [apps[index].path]) }
        let originals = apps
        let rechecker = AppUpdateFreshTestRechecker { url in
            guard var app = originals.first(where: { $0.path == url.path }) else { return nil }
            if await state.updated.contains(app.id) { app.installedVersion = .init(marketing: "2.0") }
            return .init(application: app, signature: AppUpdatePerformanceTestSupport.signature(for: app))
        }
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: BatchTestCommandRunner(state: state), rechecker: rechecker, runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
        let results = await installer.install(applications: apps) { _ in }
        XCTAssertEqual(results.first(where: { $0.applicationID == "running" })?.state, .completed)
        XCTAssertEqual(results.first(where: { $0.applicationID == "refuses" })?.state, .skipped)
        XCTAssertEqual(results.first(where: { $0.applicationID == "after" })?.state, .completed)
        let events = await state.events
        let quit = try XCTUnwrap(events.firstIndex(of: "quit:running"))
        let install = try XCTUnwrap(events.firstIndex(of: "install:running"))
        let reopen = try XCTUnwrap(events.firstIndex(of: "reopen:running"))
        XCTAssertLessThan(quit, install); XCTAssertLessThan(install, reopen)
        XCTAssertFalse(events.contains("install:refuses")); XCTAssertFalse(events.contains("reopen:refuses"))
    }

    func testHomebrewPostUpdateTeamMismatchFailsWithEvidence() async throws {
        let state = BatchTestState()
        var app = package("gui", kind: .cask)
        app.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(token: "gui", appBundlePaths: [app.path])
        let original = app
        let rechecker = AppUpdateFreshTestRechecker { _ in
            var observed = original
            if await state.updated.contains("gui") { observed.installedVersion = .init(marketing: "2.0"); observed.signingTeamIdentifier = "CHANGED" }
            return .init(application: observed, signature: AppUpdatePerformanceTestSupport.signature(for: observed))
        }
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: BatchTestCommandRunner(state: state), rechecker: rechecker, runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
        let results = await installer.install(applications: [app]) { _ in }
        XCTAssertEqual(results.first?.state, .failed)
        XCTAssertTrue(results.first?.detail.contains("TEAM123 → CHANGED") == true)
    }

    func testUpdatedBrewArtifactCannotCompleteAnUnchangedSelectedCopy() async throws {
        let state = BatchTestState()
        var app = package("moved", kind: .cask)
        let artifact = "/fixture/actual.app"
        app.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(token: "moved", appBundlePaths: [artifact])
        let original = app
        let rechecker = AppUpdateFreshTestRechecker { url in
            var observed = original
            if await state.updated.contains("moved"), url.path == artifact { observed.installedVersion = .init(marketing: "2.0") }
            return .init(application: observed, signature: AppUpdatePerformanceTestSupport.signature(for: observed))
        }
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: BatchTestCommandRunner(state: state),
            rechecker: rechecker, runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
        let results = await installer.install(applications: [app]) { _ in }
        XCTAssertEqual(results.first?.state, .failed)
        XCTAssertNil(results.first?.observedVersion)
        let calls = await state.commands
        XCTAssertEqual(calls.filter { $0.first == "upgrade" }.count, 1)
    }

    func testAuthorizationCoalescesAndButtonCountEqualsFrozenExecutionPlan() async throws {
        let authorization = BatchTestAuthorization()
        let executor = ProviderBackedApplicationUpdateExecutor(runtime: runtime(BatchTestState()), batchAuthorization: authorization,
            heavyWorkCoordinator: HeavyWorkCoordinator(), availableDiskCapacity: { _ in 10_000_000_000 })
        var apps = [package("a", kind: .cask), package("b", kind: .formula)]
        apps[0].requiresAdministratorAuthorization = true
        apps[1].requiresAdministratorAuthorization = true
        apps[0].isRunning = true; apps[0].requiresApplicationQuit = true
        let session = UUID()
        await executor.beginBatch(applications: apps, sessionID: session)
        await executor.beginBatch(applications: apps, sessionID: session) // Pause/resume must not request again.
        let requests = await authorization.requests
        XCTAssertEqual(requests, 1)
        let frozen = FrozenUpdatePlan(applications: apps)
        let presentation = AppUpdateBatchPresentation(applications: apps)
        XCTAssertEqual(presentation.count, frozen.executionPlan.batchCount)
        XCTAssertEqual(presentation.count, 2)
        XCTAssertEqual(presentation.runningCount, 1)
        XCTAssertTrue(presentation.needsAuthorization)
        XCTAssertEqual(AppUpdateService.oneClickPlan(for: apps).automaticCount, 2)
        await executor.endBatch(sessionID: session)
    }

    func testAppStoreWithTrustedMasIsAutomaticWithoutMasOpensStore() async throws {
        let app = AppUpdateTestFixtures.application(id: "store", bundleIdentifier: "com.example.store", version: "1.0", availableVersion: "2.0", provider: .macAppStore,
            sourceEvidence: ["valid-code-signature", "signed-bundle-identity"])
        let record = AppStoreOutdatedInfo(currentVersion: "1.0", latestVersion: "2.0", productID: 123)
        let trusted = MacAppStoreProvider(authorizedUpgrade: { _ in XCTFail("Scanning must not install") }, receiptVerifier: BatchTestReceipt(),
            catalogResolver: BatchTestCatalog(), masExecutableProvider: { URL(fileURLWithPath: "/fake/mas") }, outdatedProvider: { ["com.example.store": record] })
        let missing = MacAppStoreProvider(authorizedUpgrade: { _ in XCTFail("No mas") }, receiptVerifier: BatchTestReceipt(),
            catalogResolver: BatchTestCatalog(), masExecutableProvider: { nil }, outdatedProvider: { [:] })
        let automatic = await ApplicationUpdateProviderRegistry(providers: [trusted]).classify(app)
        let fallback = await ApplicationUpdateProviderRegistry(providers: [missing]).classify(app)
        XCTAssertTrue(automatic.canAutomaticallyUpdate)
        XCTAssertTrue(automatic.canJoinAutomaticUpdateBatch)
        XCTAssertEqual(automatic.updateCapability, .automatic)
        XCTAssertTrue(automatic.requiresAdministratorAuthorization)
        XCTAssertFalse(fallback.canJoinAutomaticUpdateBatch)
        XCTAssertEqual(ApplicationUpdatePlanBuilder.destination(for: fallback), .appStore)
    }

    func testAutomaticHomebrewCannotEnterOrRemainInLegacyWebsiteQueue() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        var app = package("font", kind: .cask)
        app.officialSource = .init(applicationIdentity: app.identity, providerType: .homebrew, developerName: nil,
            homepageURL: URL(string: "https://example.com"), updatePageURL: URL(string: "https://example.com/update"), releaseFeedURL: nil,
            directDownloadURL: nil, allowedHosts: ["example.com"], expectedBundleIdentifier: app.bundleIdentifier,
            expectedTeamIdentifier: app.signingTeamIdentifier, expectedDesignatedRequirement: nil, verificationMethod: .signedRegistry,
            trustLevel: .registryVerified, lastVerifiedAt: nil, capability: .manualWebsite, expectedPackageExtensions: [], officialGitHubRepository: nil)
        let store = FileWebsiteUpdateQueueStore(fileURL: root.appendingPathComponent("website.json"))
        let queue = WebsiteUpdateQueue(store: store)
        do { _ = try await queue.start(applications: [app]); XCTFail("Automatic package must not be queued as website-guided") }
        catch WebsiteUpdateQueueError.automaticUpdateAvailable {}
        var legacy = app
        legacy.canAutomaticallyUpdate = false; legacy.updateCapability = .websiteGuided
        _ = try await queue.start(applications: [legacy])
        let restored = try await WebsiteUpdateQueue(store: store).restore(applications: [app])
        XCTAssertEqual(restored?.items.first?.state, .deferred)
        XCTAssertTrue(restored?.items.first?.detail?.contains("全部更新") == true || restored?.items.first?.detail?.contains("Update All") == true)
    }

    func testExecutionTimeBrewVersionDriftPreventsAnyUpgrade() async throws {
        let state = BatchTestState(); await state.markUpdated("drift")
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: BatchTestCommandRunner(state: state), runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
        let results = await installer.install(applications: [package("drift", kind: .formula)]) { _ in }
        XCTAssertEqual(results.first?.state, .failed)
        let calls = await state.commands
        XCTAssertFalse(calls.contains { $0.first == "upgrade" })
    }

    func testAppStoreAccountFailureIsSkippedAndExplainsStoreHandoff() async throws {
        let app = AppUpdateTestFixtures.application(id: "store", bundleIdentifier: "com.example.store", version: "1.0", availableVersion: "2.0", provider: .macAppStore,
            sourceEvidence: ["valid-code-signature", "signed-bundle-identity"])
        let record = AppStoreOutdatedInfo(currentVersion: "1.0", latestVersion: "2.0", productID: 123)
        let provider = MacAppStoreProvider(authorizedUpgrade: { _ in throw NSError(domain: "mas.fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not signed in to Apple Account"]) },
            receiptVerifier: BatchTestReceipt(), catalogResolver: BatchTestCatalog(), masExecutableProvider: { URL(fileURLWithPath: "/fake/mas") }, outdatedProvider: { ["com.example.store": record] })
        let classified = await ApplicationUpdateProviderRegistry(providers: [provider]).classify(app)
        let prepared = try await provider.prepareUpdate(classified)
        let result = try await provider.install(prepared) { _ in }
        XCTAssertEqual(result.state, .skipped)
        XCTAssertTrue(result.detail.contains("App Store"))
    }

    func testPrivilegedBatchContractAllowsOnlyExactNonAppleReplacementTargets() {
        let target = AuthorizedUpdateTarget(path: "/Applications/Example.app", bundleIdentifier: "com.example.app", teamIdentifier: "TEAM", version: "1", build: "1")
        XCTAssertTrue(AuthorizedApplicationReplacementBatch(sessionID: UUID(), targets: [target]).isValid)
        let apple = AuthorizedUpdateTarget(path: "/Applications/Safari.app", bundleIdentifier: "com.apple.Safari", teamIdentifier: "APPLE", version: "1", build: "1")
        XCTAssertFalse(AuthorizedApplicationReplacementBatch(sessionID: UUID(), targets: [apple]).isValid)
        let nested = AuthorizedUpdateTarget(path: "/Applications/Utilities/Example.app", bundleIdentifier: "com.example.app", teamIdentifier: "TEAM", version: "1", build: "1")
        XCTAssertFalse(AuthorizedApplicationReplacementBatch(sessionID: UUID(), targets: [nested]).isValid)
    }

    func testSameCaskAllArtifactsQuitOnceUpgradeOnceAndEachCopyReopens() async throws {
        let state = BatchTestState()
        await state.setRunning(["A.app", "B.app"])
        let apps = suiteApplications()
        let installer = suiteInstaller(state: state, apps: apps)
        let results = await installer.install(applications: apps) { _ in }
        XCTAssertEqual(results.map(\.state), [.completed, .completed], results.map(\.detail).joined(separator: "\n"))
        let events = await state.events
        XCTAssertTrue(events.contains("quit:A.app")); XCTAssertTrue(events.contains("quit:B.app"))
        XCTAssertTrue(events.contains("reopen:A.app")); XCTAssertTrue(events.contains("reopen:B.app"))
        let calls = await state.commands.filter { $0.first == "upgrade" }
        XCTAssertEqual(calls, [["upgrade", "--cask", "suite"]])
    }
    func testRefusalInAnotherCaskArtifactSkipsWholePackageAndContinues() async throws {
        let state = BatchTestState()
        await state.setRunning(["A.app", "B.app"]); await state.setRefuses(["B.app"])
        let apps = suiteApplications()
        let installer = suiteInstaller(state: state, apps: apps)
        // Only A is a selected row. B is affected solely through the cask's
        // artifact declaration, so clearing that declaration must break this test.
        let results = await installer.install(applications: [apps[0], package("after", kind: .formula)]) { _ in }
        XCTAssertEqual(results.first(where: { $0.applicationID == "A" })?.state, .skipped)
        XCTAssertNil(results.first(where: { $0.applicationID == "B" }))
        XCTAssertEqual(results.first(where: { $0.applicationID == "after" })?.state, .completed)
        let events = await state.events
        XCTAssertEqual(events.filter { $0.hasPrefix("quit:") }, ["quit:A.app", "quit:B.app"])
        XCTAssertFalse(events.contains("install:suite"))
        XCTAssertTrue(events.contains("reopen:A.app"))
        XCTAssertFalse(events.contains("reopen:B.app"))
    }
    func testLatestWithoutAppNeedsEvidenceAndIsNeverAutomaticallyRetried() async throws {
        let state = BatchTestState(); await state.failToken("bad")
        var latest = package("latest-tool", kind: .cask)
        latest.availableVersion = .init(marketing: "latest")
        latest.homebrewMetadata = .init(token: "latest-tool", kind: .cask, homepageURL: nil, installedVersions: ["latest"], currentVersion: "latest",
            isOutdated: true, outdatedProvenance: .greedy, isPinned: false, isDisabled: false, isDeprecated: false, autoUpdates: true, requiresManualInstaller: false, appBundlePaths: [])
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: LatestBatchRunner(state: state), runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
        let results = await installer.install(applications: [latest, package("bad", kind: .cask)]) { _ in }
        XCTAssertEqual(results.first(where: { $0.applicationID == latest.id })?.state, .needsReconciliation)
        let calls = await state.commands.filter { $0.first == "upgrade" }
        XCTAssertEqual(calls.filter { $0.contains("latest-tool") }.count, 1)
    }
    func testProducerOutputBoundAndStopReceiptDoNotMisreportUnstoppableInstall() throws {
        var budget = AppUpdateOutputBudget(limit: 16)
        try budget.append(Data(repeating: 65, count: 12))
        XCTAssertThrowsError(try budget.append(Data(repeating: 66, count: 8))) { XCTAssertEqual($0 as? AppUpdateCommandError, .outputLimit) }
        XCTAssertEqual(budget.bytes.count, 12)
        XCTAssertEqual(AppUpdateStopReceipt.result(confirmedStopped: true, reason: .cancelled), .cancelled)
        XCTAssertEqual(AppUpdateStopReceipt.result(confirmedStopped: false, reason: .cancelled), .needsReconciliation)
        XCTAssertEqual(AppUpdateStopReceipt.result(confirmedStopped: false, reason: .outputLimit), .needsReconciliation)
        XCTAssertEqual(AppUpdateStopReceipt.result(confirmedStopped: true, reason: .cancelled, systemInstaller: true), .needsReconciliation)
        XCTAssertEqual(AppUpdateStopReceipt.result(confirmedStopped: true, reason: .outputLimit, systemInstaller: true), .needsReconciliation)
        XCTAssertTrue(AppUpdateStopReceipt.mayUseSystemInstaller(arguments: ["-A", "/fake/mas", "upgrade", "123"], environment: ["SUDO_ASKPASS": "/fake/askpass"]))
        XCTAssertFalse(AppUpdateStopReceipt.mayUseSystemInstaller(arguments: ["list", "--versions"], environment: ["SUDO_ASKPASS": "/fake/askpass"]))
    }
    func testApplicationRelaunchBeforeBrewSkipsWholePackageAndOtherPackageContinues() async throws {
        let state = BatchTestState()
        let apps = suiteApplications()
        var installer = suiteInstaller(state: state, apps: apps)
        // The first package snapshots/quit pass reports stopped. At the final
        // pre-execution check B has relaunched, so no suite upgrade may run.
        let checks = BatchRunningCheckProbe()
        installer.runtime = .init(isRunning: { url in await checks.isRunning(url) }, requestQuit: { _ in true }, reopen: { _ in }, wait: {})
        let results = await installer.install(applications: apps + [package("after", kind: .formula)]) { _ in }
        XCTAssertEqual(results.filter { ["A", "B"].contains($0.applicationID) }.map(\.state), [.skipped, .skipped])
        XCTAssertEqual(results.first(where: { $0.applicationID == "after" })?.state, .completed)
        let calls = await state.commands
        XCTAssertFalse(calls.contains(where: { $0.first == "upgrade" && $0.contains("suite") }))
    }
    func testUnconfirmedSystemInstallationReadsVersionsWithoutRetryAndKeepsPending() async throws {
        let state = BatchTestState()
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: UnconfirmedBatchRunner(state: state), runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
        let app = package("tool", kind: .formula)
        let results = await installer.install(applications: [app]) { _ in }
        XCTAssertEqual(results.first?.state, .needsReconciliation)
        XCTAssertTrue(results.first?.detail.contains("tool: 2.0") == true)
        let calls = await state.commands
        XCTAssertEqual(calls.filter { $0.first == "upgrade" }.count, 1)
        XCTAssertEqual(calls.filter { $0.first == "list" }.count, 2)
    }
    func testCancellationAfterAdministratorCommandReplyStillReadsBackAndDoesNotClaimStopped() async throws {
        let state = BatchTestState()
        var app = package("admin", kind: .cask)
        app.requiresAdministratorAuthorization = true
        var installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: CancelAfterReplyBatchRunner(state: state), runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
        installer.administratorEnvironment = ["SUDO_ASKPASS": "/sealed/fake-askpass"]
        let frozen = app; let executor = installer
        let task = Task { await executor.install(applications: [frozen]) { _ in } }
        let results = await task.value
        XCTAssertEqual(results.first?.state, .needsReconciliation)
        XCTAssertTrue(results.first?.detail.contains("admin: 2.0") == true)
        let calls = await state.commands
        XCTAssertEqual(calls.filter { $0.first == "upgrade" }.count, 1)
        XCTAssertEqual(calls.filter { $0.first == "list" }.count, 2)
    }
    func testNoAppPackageReadOnlyReconciliationUsesBrewAndLatestStaysPending() async throws {
        let state = BatchTestState(); await state.markUpdated("tool")
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: BatchTestCommandRunner(state: state), runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
        let app = package("tool", kind: .formula)
        let task = ApplicationUpdateTask(sessionID: UUID(), application: app, state: .needsReconciliation)
        let result = try await installer.reconcile(application: app, task: task)
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.observedVersion?.marketing, "2.0")
        let calls = await state.commands
        XCTAssertEqual(calls.map { $0.first }, ["list"])
        var latest = package("latest-tool", kind: .cask)
        latest.availableVersion = .init(marketing: "latest")
        latest.homebrewMetadata = .init(token: "latest-tool", kind: .cask, homepageURL: nil, installedVersions: ["latest"], currentVersion: "latest",
            isOutdated: true, outdatedProvenance: .greedy, isPinned: false, isDisabled: false, isDeprecated: false, autoUpdates: true, requiresManualInstaller: false, appBundlePaths: [])
        var latestInstaller = installer
        latestInstaller.command = LatestBatchRunner(state: state)
        let latestTask = ApplicationUpdateTask(sessionID: UUID(), application: latest, state: .needsReconciliation)
        let pending = try await latestInstaller.reconcile(application: latest, task: latestTask)
        XCTAssertEqual(pending.state, .needsReconciliation)
        let finalCalls = await state.commands
        XCTAssertFalse(finalCalls.contains(where: { $0.first == "upgrade" }))
    }
    func testDeclinedAuthorizationSkipsAdministratorPackageAndUpdatesOrdinaryPackage() async throws {
        let state = BatchTestState()
        var admin = package("admin", kind: .cask)
        admin.requiresAdministratorAuthorization = true
        let ordinary = package("ordinary", kind: .formula)
        let installer = HomebrewBatchInstaller(executable: { URL(fileURLWithPath: "/fake/brew") }, command: BatchTestCommandRunner(state: state), runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
        let results = await installer.install(applications: [admin, ordinary]) { _ in }
        XCTAssertEqual(results.first(where: { $0.applicationID == "admin" })?.state, .skipped)
        XCTAssertEqual(results.first(where: { $0.applicationID == "ordinary" })?.state, .completed)
        let calls = await state.commands
        XCTAssertFalse(calls.contains(where: { $0.contains("admin") }))
    }
    private func suiteApplications() -> [InstalledApplication] {
        ["A", "B"].map { name in
            var app = package("suite", kind: .cask)
            // Each displayed application is distinct but both own one token.
            app = AppUpdateTestFixtures.application(id: name, bundleIdentifier: "com.example." + name, path: "/fixture/" + name + ".app",
                version: "1.0", build: "", availableVersion: "2.0", provider: .homebrew, status: .automaticallyUpdatable,
                sourceEvidence: ["homebrew-cli-json-v2"], homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(token: "suite", appBundlePaths: ["/fixture/A.app", "/fixture/B.app"]),
                canAutomaticallyUpdate: true, requiresUserInteraction: false)
            return app
        }
    }
    private func suiteInstaller(state: BatchTestState, apps: [InstalledApplication]) -> HomebrewBatchInstaller {
        .init(executable: { URL(fileURLWithPath: "/fake/brew") }, command: BatchTestCommandRunner(state: state), rechecker: AppUpdateFreshTestRechecker { url in
            guard var app = apps.first(where: { $0.path == url.path }) else { return nil }
            if await state.updated.contains("suite") { app.installedVersion = .init(marketing: "2.0") }
            return .init(application: app, signature: AppUpdatePerformanceTestSupport.signature(for: app))
        }, runtime: runtime(state), captureExecutable: appUpdateFixtureExecutable)
    }

    private func package(_ token: String, kind: HomebrewPackageKind, greedy: Bool = false) -> InstalledApplication {
        var app = AppUpdateTestFixtures.application(id: token, path: "/fixture/\(token)", version: "1.0", build: "", availableVersion: "2.0", provider: .homebrew,
            status: .automaticallyUpdatable, sourceEvidence: ["homebrew-cli-json-v2"],
            homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(token: token, kind: kind, outdatedProvenance: greedy ? .greedy : .plain, appBundlePaths: []),
            canAutomaticallyUpdate: true, requiresUserInteraction: false)
        app.packageKind = .commandLineTool
        return app
    }
    private func runtime(_ state: BatchTestState) -> ApplicationUpdateBatchRuntime {
        .init(isRunning: { await state.running.contains($0.lastPathComponent) }, requestQuit: { await state.quit($0.lastPathComponent) },
            reopen: { await state.reopen($0.lastPathComponent) }, wait: { await Task.yield() }, quitTimeout: .milliseconds(50))
    }
}

private actor BatchTestState {
    var commands = [[String]](); var updated = Set<String>(); var running = Set<String>(); var refuses = Set<String>(); var events = [String](); var failure: String?
    func setRunning(_ values: Set<String>) { running = values }
    func setRefuses(_ values: Set<String>) { refuses = values }
    func failToken(_ value: String) { failure = value }
    func markUpdated(_ value: String) { updated.insert(value) }
    func event(_ value: String) { events.append(value) }
    func quit(_ value: String) -> Bool { events.append("quit:" + value); if refuses.contains(value) { return false }; running.remove(value); return true }
    func reopen(_ value: String) { events.append("reopen:" + value) }
    func run(_ arguments: [String]) throws -> Data {
        commands.append(arguments)
        if arguments.first == "list", let token = arguments.last { return Data("\(token) \(updated.contains(token) ? "2.0" : "1.0")\n".utf8) }
        guard arguments.first == "upgrade" else { throw NSError(domain: "Unexpected test command", code: 1) }
        for token in arguments.dropFirst().filter({ !$0.hasPrefix("--") }) {
            if token == failure { throw AppUpdateCommandError.failed(1, "InjectedBrewFailure") }
            updated.insert(token); events.append("install:" + token)
        }
        return Data()
    }
}
private struct BatchTestCommandRunner: HomebrewCommandRunning {
    let state: BatchTestState
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        XCTAssertEqual(executableURL.path, "/fake/brew"); XCTAssertEqual(environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
        return try await state.run(arguments)
    }
}
private actor BatchTestAuthorization: AppUpdateBatchAuthorizing {
    var requests = 0
    func prepare(applications: [InstalledApplication], sessionID: UUID) async throws { requests += 1 }
    func upgrade(productID: UInt64) async throws { XCTFail("Unused") }
    func replace(candidate: URL, application: InstalledApplication) async throws { XCTFail("Unused") }
    func finish() async {}
}
private struct BatchTestReceipt: MacAppStoreReceiptVerifying { func verifyReceipt(at applicationURL: URL) async -> Bool { true } }
private struct BatchTestCatalog: AppStoreCatalogResolving {
    func resolve(bundleIdentifier: String, storefront: String) async throws -> AppStoreCatalogResolution {
        .matched(.init(bundleIdentifier: bundleIdentifier, version: .init(marketing: "2.0"), productURL: URL(string: "https://apps.apple.com/app/id123")!, sellerName: nil, releaseDate: nil, releaseNotes: nil, downloadSize: nil))
    }
}

private struct LatestBatchRunner: HomebrewCommandRunning {
    let state: BatchTestState
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        if arguments.first == "list", arguments.last == "latest-tool" { return Data("latest-tool latest\n".utf8) }
        return try await state.run(arguments)
    }
}
private struct SymbolicVariantRunner: HomebrewCommandRunning {
    let symbolic: String
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        if arguments.first == "list" { return Data("symbolic-tool \(symbolic)\n".utf8) }
        XCTAssertEqual(arguments, ["upgrade", "--cask", "--greedy", "symbolic-tool"])
        return Data()
    }
}
private final class BatchExecutableChangeProbe: @unchecked Sendable {
    private let lock = NSLock(); private var changed = false
    func change() { lock.withLock { changed = true } }
    func capture(_ url: URL) throws -> AppUpdateExecutableIdentity {
        let changed = lock.withLock { changed }
        return .init(url: url, resolvedURL: url, inode: 1, device: 1, owner: getuid(), mode: 0o755,
            sha256: String(repeating: changed ? "b" : "a", count: 64))
    }
}
private struct SourceChangeBatchRunner: HomebrewCommandRunning {
    let state: BatchTestState; let identity: BatchExecutableChangeProbe
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        let result = try await state.run(arguments)
        if arguments.first == "list" { identity.change() }
        return result
    }
}
private actor BatchRunningCheckProbe {
    private var bChecks = 0
    func isRunning(_ url: URL) -> Bool {
        guard url.lastPathComponent == "B.app" else { return false }
        bChecks += 1
        return bChecks > 1
    }
}
private struct UnconfirmedBatchRunner: HomebrewCommandRunning {
    let state: BatchTestState
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        let data = try await state.run(arguments)
        if arguments.first == "upgrade" { throw AppUpdateCommandError.needsReconciliation }
        return data
    }
}
private struct CancelAfterReplyBatchRunner: HomebrewCommandRunning {
    let state: BatchTestState
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        let data = try await state.run(arguments)
        if arguments.first == "upgrade" { withUnsafeCurrentTask { $0?.cancel() } }
        return data
    }
}
