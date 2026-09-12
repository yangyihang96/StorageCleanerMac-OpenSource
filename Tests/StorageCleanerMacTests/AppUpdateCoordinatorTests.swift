import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateCoordinatorTests: XCTestCase {
    @MainActor
    func testGracefulQuitRequesterUsesExactBundleIdentityAndResolvedPathWithoutForce() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actualURL = root.appendingPathComponent("Actual.app", isDirectory: true)
        let linkedURL = root.appendingPathComponent("Linked.app", isDirectory: true)
        try FileManager.default.createDirectory(at: actualURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedURL,
            withDestinationURL: actualURL
        )
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "resolved-path",
            token: "resolved-path",
            path: linkedURL.path,
            isRunning: true
        )
        let recorder = GracefulQuitRecorder(result: true)
        let requester = ApplicationUpdateGracefulQuitRequester {
            [ApplicationUpdateGracefulQuitRequester.RunningApplication(
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: actualURL,
                requestTermination: recorder.terminate
            )]
        }

        XCTAssertTrue(requester.requestGracefulQuit(for: application))
        XCTAssertEqual(recorder.terminateCount, 1)
        XCTAssertEqual(recorder.forceTerminateCount, 0)
    }

    @MainActor
    func testGracefulQuitRequesterRejectsSameBundleIdentifierAtDifferentPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plannedURL = root.appendingPathComponent("Planned.app", isDirectory: true)
        let otherURL = root.appendingPathComponent("Other.app", isDirectory: true)
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "different-copy",
            token: "different-copy",
            path: plannedURL.path,
            isRunning: true
        )
        let recorder = GracefulQuitRecorder(result: true)
        let requester = ApplicationUpdateGracefulQuitRequester {
            [ApplicationUpdateGracefulQuitRequester.RunningApplication(
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: otherURL,
                requestTermination: recorder.terminate
            )]
        }

        XCTAssertFalse(requester.requestGracefulQuit(for: application))
        XCTAssertEqual(recorder.terminateCount, 0)
        XCTAssertEqual(recorder.forceTerminateCount, 0)
    }

    @MainActor
    func testGracefulQuitRequesterTreatsPathCaseAsExactIdentity() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plannedURL = root.appendingPathComponent("Planned.app", isDirectory: true)
        let caseChangedURL = root.appendingPathComponent("planned.app", isDirectory: true)
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "case-sensitive-copy",
            token: "case-sensitive-copy",
            path: plannedURL.path,
            isRunning: true
        )
        let recorder = GracefulQuitRecorder(result: true)
        let requester = ApplicationUpdateGracefulQuitRequester {
            [ApplicationUpdateGracefulQuitRequester.RunningApplication(
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: caseChangedURL,
                requestTermination: recorder.terminate
            )]
        }

        XCTAssertFalse(requester.requestGracefulQuit(for: application))
        XCTAssertEqual(recorder.terminateCount, 0)
        XCTAssertEqual(recorder.forceTerminateCount, 0)
    }

    @MainActor
    func testConfirmedQueueRequestsQuitOnceAndRejectedRequestKeepsWaiting() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ApplicationUpdateQueueRepository(
            fileURL: root.appendingPathComponent("queue.json")
        )
        let executor = ScriptedAppUpdateExecutor(
            outcomes: ["waiting-refused": .success(ApplicationVersion(marketing: "2.0"))]
        )
        let coordinator = ApplicationUpdateCoordinator(
            repository: repository,
            executor: executor
        )
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "waiting-refused",
            token: "waiting-refused",
            path: root.appendingPathComponent("Waiting.app").path,
            isRunning: true
        )
        let recorder = GracefulQuitRecorder(result: false)
        let requester = ApplicationUpdateGracefulQuitRequester {
            [ApplicationUpdateGracefulQuitRequester.RunningApplication(
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL,
                requestTermination: recorder.terminate
            )]
        }
        let store = ScanStore(
            applicationUpdateCoordinator: coordinator,
            applicationUpdateGracefulQuitRequester: requester
        )
        store.appUpdates = [application]

        store.previewOneClickAppUpdates()
        XCTAssertEqual(recorder.terminateCount, 0)
        store.confirmOneClickAppUpdates()
        try await waitForMainActorCondition {
            recorder.terminateCount == 1
                && store.appUpdateQueueSnapshot?.tasks.first?.state == .waitingForQuit
        }

        XCTAssertEqual(
            store.appUpdateQueueSnapshot?.tasks.first?.state,
            .waitingForQuit
        )
        XCTAssertEqual(recorder.terminateCount, 1)
        XCTAssertEqual(recorder.forceTerminateCount, 0)
        let executionOrder = await executor.executionOrder()
        XCTAssertTrue(executionOrder.isEmpty)

        store.cancelOneClickAppUpdates()
        try await waitForMainActorCondition { !store.isRunningOneClickUpdate }
    }

    func testProviderExecutorRechecksEligibilityBeforeResumingPersistedIntent() async throws {
        var stale = AppUpdateTestFixtures.strictHomebrewApplication(id: "stale-restored")
        stale.canAutomaticallyUpdate = false
        let task = ApplicationUpdateTask(
            sessionID: UUID(),
            application: stale
        )
        let executor = ProviderBackedApplicationUpdateExecutor(
            heavyWorkCoordinator: HeavyWorkCoordinator()
        )

        do {
            _ = try await executor.execute(
                application: stale,
                task: task,
                progress: { _ in }
            )
            XCTFail("Expected the stale persisted intent to fail closed")
        } catch ProviderBackedUpdateExecutorError.applicationNoLongerEligible {
            // Expected: the provider is not invoked.
        }
    }

    func testMetadataReaderSeesReplacementVersionAtTheSameBundlePath() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try makeApplicationBundle(
            in: root,
            bundleIdentifier: "com.example.replaced",
            version: "1.0",
            build: "100"
        )
        let reader = ApplicationMetadataReader(
            signatureInspector: FixedApplicationSignatureInspector(
                teamIdentifier: "TEAM123",
                codeSigningIdentifier: "com.example.replaced"
            )
        )
        let runningState = ApplicationRunningStateSnapshot(
            bundleIdentifiers: [],
            normalizedBundlePaths: []
        )
        let before = await reader.read(applicationURL: appURL, runningState: runningState)

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        var info = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: infoURL),
                format: nil
            ) as? [String: Any]
        )
        info["CFBundleShortVersionString"] = "2.0"
        info["CFBundleVersion"] = "200"
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: infoURL, options: .atomic)

        let after = await reader.read(applicationURL: appURL, runningState: runningState)

        XCTAssertEqual(before?.installedVersion, ApplicationVersion(marketing: "1.0", build: "100"))
        XCTAssertEqual(after?.installedVersion, ApplicationVersion(marketing: "2.0", build: "200"))
    }

    func testExecutorPreflightWaitsWhenApplicationStartedAfterQueueing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try makeApplicationBundle(
            in: root,
            bundleIdentifier: "com.example.started",
            version: "1.0",
            build: "100"
        )
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "started",
            token: "started",
            path: appURL.path
        )
        let task = ApplicationUpdateTask(sessionID: UUID(), application: application)
        let executor = ProviderBackedApplicationUpdateExecutor(
            metadataReader: ApplicationMetadataReader(
                signatureInspector: FixedApplicationSignatureInspector(
                    teamIdentifier: "TEAM123",
                    codeSigningIdentifier: application.bundleIdentifier
                )
            ),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            runningStateProvider: {
                ApplicationRunningStateSnapshot(
                    bundleIdentifiers: [application.bundleIdentifier],
                    normalizedBundlePaths: [ApplicationPathNormalizer.normalizedPath(for: appURL)]
                )
            }
        )

        let result = try await executor.execute(
            application: application,
            task: task,
            progress: { _ in }
        )

        XCTAssertEqual(result.state, .waitingForQuit)
        XCTAssertNil(result.observedVersion)
    }

    func testExecutorPreflightRejectsChangedOnDiskVersionBeforeProviderRuns() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try makeApplicationBundle(
            in: root,
            bundleIdentifier: "com.example.changed",
            version: "1.1",
            build: "110"
        )
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "changed",
            token: "changed",
            path: appURL.path
        )
        let task = ApplicationUpdateTask(sessionID: UUID(), application: application)
        let executor = ProviderBackedApplicationUpdateExecutor(
            metadataReader: ApplicationMetadataReader(
                signatureInspector: FixedApplicationSignatureInspector(
                    teamIdentifier: "TEAM123",
                    codeSigningIdentifier: application.bundleIdentifier
                )
            ),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            runningStateProvider: {
                ApplicationRunningStateSnapshot(bundleIdentifiers: [], normalizedBundlePaths: [])
            }
        )

        do {
            _ = try await executor.execute(
                application: application,
                task: task,
                progress: { _ in }
            )
            XCTFail("Expected the changed click-time version to fail closed")
        } catch ProviderBackedUpdateExecutorError.applicationVersionChanged {
            // Expected: no provider command is started.
        }
    }

    func testExecutorPreflightRejectsChangedSigningIdentityBeforeProviderRuns() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try makeApplicationBundle(
            in: root,
            bundleIdentifier: "com.example.identity-preflight",
            version: "1.0",
            build: "100"
        )
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "identity-preflight",
            token: "identity-preflight",
            path: appURL.path
        )
        let task = ApplicationUpdateTask(sessionID: UUID(), application: application)
        let executor = ProviderBackedApplicationUpdateExecutor(
            metadataReader: ApplicationMetadataReader(
                signatureInspector: FixedApplicationSignatureInspector(
                    teamIdentifier: "OTHERTEAM",
                    codeSigningIdentifier: application.bundleIdentifier
                )
            ),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            runningStateProvider: {
                ApplicationRunningStateSnapshot(bundleIdentifiers: [], normalizedBundlePaths: [])
            }
        )

        do {
            _ = try await executor.execute(
                application: application,
                task: task,
                progress: { _ in }
            )
            XCTFail("Expected the changed signing identity to fail closed")
        } catch ProviderBackedUpdateExecutorError.applicationIdentityChanged {
            // Expected: no provider command is started.
        }
    }

    func testProviderExecutorPreparesInstallsAndVerifiesOnDiskVersionAndIdentity() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleIdentifier = "com.example.provider-success"
        let appURL = try makeApplicationBundle(
            in: root,
            bundleIdentifier: bundleIdentifier,
            version: "1.0",
            build: "100"
        )
        let installedURL = try makeApplicationBundle(
            in: root,
            bundleIdentifier: bundleIdentifier,
            version: "1.0",
            build: "100"
        )
        var application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "provider-success",
            token: "provider-success",
            path: appURL.path
        )
        application.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(
            token: "provider-success",
            appBundlePaths: [appURL.path, installedURL.path]
        )
        let task = ApplicationUpdateTask(sessionID: UUID(), application: application)
        let provider = SuccessfulApplicationUpdateProvider(
            applicationURL: installedURL,
            targetVersion: ApplicationVersion(marketing: "2.0", build: "200")
        )
        let executor = ProviderBackedApplicationUpdateExecutor(
            providerRegistry: ApplicationUpdateProviderRegistry(providers: [provider]),
            metadataReader: ApplicationMetadataReader(
                signatureInspector: FixedApplicationSignatureInspector(
                    teamIdentifier: "TEAM123",
                    codeSigningIdentifier: bundleIdentifier
                )
            ),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            runningStateProvider: {
                ApplicationRunningStateSnapshot(bundleIdentifiers: [], normalizedBundlePaths: [])
            },
            availableDiskCapacity: { _ in Int64.max }
        )

        let result = try await executor.execute(
            application: application,
            task: task,
            progress: { _ in }
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(
            result.observedVersion,
            ApplicationVersion(marketing: "2.0", build: "200")
        )
        let prepareCallCount = await provider.prepareCallCount
        let installCallCount = await provider.installCallCount
        XCTAssertEqual(prepareCallCount, 1)
        XCTAssertEqual(installCallCount, 1)
    }

    func testDiskSpacePolicyUsesKnownPackageExpansionAndUnknownProviderHeadroom() {
        let policy = ApplicationUpdateDiskSpacePolicy(
            minimumUnknownDownloadHeadroomBytes: 1_000,
            knownDownloadMultiplier: 3
        )
        let unknown = AppUpdateTestFixtures.strictHomebrewApplication(id: "unknown-size")
        var known = unknown
        known.downloadSize = 600

        XCTAssertEqual(policy.requiredBytes(for: unknown), 1_000)
        XCTAssertEqual(policy.requiredBytes(for: known), 1_800)
    }

    func testExecutorRejectsInsufficientDiskSpaceBeforePreparingProvider() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try makeApplicationBundle(
            in: root,
            bundleIdentifier: "com.example.low-disk",
            version: "1.0",
            build: "100"
        )
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "low-disk",
            token: "low-disk",
            path: appURL.path
        )
        let task = ApplicationUpdateTask(sessionID: UUID(), application: application)
        let executor = ProviderBackedApplicationUpdateExecutor(
            metadataReader: ApplicationMetadataReader(
                signatureInspector: FixedApplicationSignatureInspector(
                    teamIdentifier: "TEAM123",
                    codeSigningIdentifier: application.bundleIdentifier
                )
            ),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            runningStateProvider: {
                ApplicationRunningStateSnapshot(bundleIdentifiers: [], normalizedBundlePaths: [])
            },
            diskSpacePolicy: ApplicationUpdateDiskSpacePolicy(
                minimumUnknownDownloadHeadroomBytes: 1_024,
                knownDownloadMultiplier: 3
            ),
            availableDiskCapacity: { _ in 512 }
        )

        do {
            _ = try await executor.execute(
                application: application,
                task: task,
                progress: { _ in }
            )
            XCTFail("Expected the disk-space preflight to fail closed")
        } catch let ProviderBackedUpdateExecutorError.insufficientDiskSpace(
            requiredBytes,
            availableBytes,
            _
        ) {
            XCTAssertEqual(requiredBytes, 1_024)
            XCTAssertEqual(availableBytes, 512)
        }
    }

    func testPlanOnlyPlacesStrictHomebrewItemsInAutomaticGroup() {
        let automatic = AppUpdateTestFixtures.strictHomebrewApplication(id: "automatic")
        var pinned = AppUpdateTestFixtures.strictHomebrewApplication(id: "pinned", token: "pinned")
        pinned.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(
            token: "pinned",
            isPinned: true,
            appBundlePaths: [pinned.path]
        )
        pinned.canAutomaticallyUpdate = false
        pinned.requiresUserInteraction = true

        let running = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "running",
            token: "running",
            path: "/Applications/Running.app",
            isRunning: true
        )
        let authorization = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "authorization",
            token: "authorization",
            path: "/Applications/Authorization.app",
            requiresAuthorization: true
        )
        let appStore = AppUpdateTestFixtures.application(
            id: "store",
            availableVersion: "2.0",
            provider: .macAppStore,
            status: .updateAvailable,
            canAutomaticallyUpdate: false
        )
        let website = AppUpdateTestFixtures.application(
            id: "website",
            availableVersion: "2.0",
            provider: .officialWebsite,
            status: .officialInstallerAvailable,
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )
        let system = AppUpdateTestFixtures.application(
            id: "system",
            provider: .systemManaged,
            status: .systemManaged,
            isSystem: true,
            requiresUserInteraction: false
        )
        let manual = AppUpdateTestFixtures.application(
            id: "manual",
            availableVersion: "2.0",
            status: .updateAvailable
        )

        let plan = ApplicationUpdatePlanBuilder().build(
            applications: [automatic, pinned, running, authorization, appStore, website, system, manual],
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(plan.automaticApplicationIDs, ["automatic"])
        XCTAssertEqual(plan.requiresQuitApplicationIDs, ["running"])
        XCTAssertEqual(plan.requiresAuthorizationApplicationIDs, ["authorization"])
        XCTAssertEqual(plan.appStoreApplicationIDs, ["store"])
        XCTAssertEqual(plan.websiteApplicationIDs, ["website"])
        XCTAssertEqual(Set(plan.manualApplicationIDs), ["pinned", "manual"])
        XCTAssertEqual(plan.skippedApplicationIDs, ["system"])
    }

    func testPlanRejectsInvalidFormulaAndCaskTokens() {
        var formula = AppUpdateTestFixtures.strictHomebrewApplication(id: "formula-token")
        formula.installationSource = .homebrewFormula
        formula.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(
            token: "formula;invalid",
            kind: .formula,
            appBundlePaths: []
        )
        formula.caskToken = nil

        var cask = AppUpdateTestFixtures.strictHomebrewApplication(id: "cask-token")
        cask.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(
            token: "-invalid-cask",
            appBundlePaths: [cask.path]
        )
        cask.caskToken = "-invalid-cask"

        let plan = ApplicationUpdatePlanBuilder().build(applications: [formula, cask])

        XCTAssertTrue(plan.automaticApplicationIDs.isEmpty)
        XCTAssertEqual(Set(plan.manualApplicationIDs), [formula.id, cask.id])
    }

    func testLegacyPreviewPlanDoesNotCountIgnoredAutomaticCandidate() {
        var ignored = AppUpdateTestFixtures.strictHomebrewApplication(id: "ignored")
        ignored.updateStatus = .ignored

        let plan = AppUpdateService.oneClickPlan(for: [ignored])

        XCTAssertEqual(plan.automaticCount, 0)
        XCTAssertTrue(plan.automaticApps.isEmpty)
    }

    func testPlanSkipsStaleTargetWhenLatestVersionRecheckFailed() {
        var failed = AppUpdateTestFixtures.strictHomebrewApplication(id: "failed-recheck")
        failed.sourceResolutionState = .resolved
        failed.versionCheckState = .failed
        failed.updateStatus = .failed

        let frozen = ApplicationUpdatePlanBuilder().build(applications: [failed])
        let preview = AppUpdateService.oneClickPlan(for: [failed])

        XCTAssertFalse(ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(failed))
        XCTAssertEqual(frozen.skippedApplicationIDs, [failed.id])
        XCTAssertTrue(frozen.automaticApplicationIDs.isEmpty)
        XCTAssertTrue(frozen.manualApplicationIDs.isEmpty)
        XCTAssertTrue(preview.isEmpty)
    }

    func testDuplicateApplicationCopyNeverEntersAutomaticPlan() {
        var duplicate = AppUpdateTestFixtures.strictHomebrewApplication(id: "duplicate")
        duplicate.isDuplicate = true
        duplicate.duplicateLocations = [
            URL(fileURLWithPath: "/Applications/Example App.app"),
            URL(fileURLWithPath: "/Users/test/Applications/Example App.app"),
        ]

        let plan = ApplicationUpdatePlanBuilder().build(applications: [duplicate])

        XCTAssertTrue(plan.automaticApplicationIDs.isEmpty)
        XCTAssertEqual(plan.manualApplicationIDs, [duplicate.id])
        XCTAssertFalse(ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(duplicate))
    }

    func testStateMachineRejectsTerminalAndOutOfOrderTransitions() {
        XCTAssertTrue(ApplicationUpdateCoordinator.isValidTransition(from: .queued, to: .checking))
        XCTAssertTrue(ApplicationUpdateCoordinator.isValidTransition(from: .checking, to: .needsReconciliation))
        XCTAssertTrue(ApplicationUpdateCoordinator.isValidTransition(from: .needsReconciliation, to: .installing))
        XCTAssertTrue(ApplicationUpdateCoordinator.isValidTransition(from: .failed, to: .queued))
        XCTAssertTrue(ApplicationUpdateCoordinator.isValidTransition(from: .installing, to: .needsReconciliation))
        XCTAssertFalse(ApplicationUpdateCoordinator.isValidTransition(from: .queued, to: .completed))
        XCTAssertFalse(ApplicationUpdateCoordinator.isValidTransition(from: .completed, to: .queued))
        XCTAssertFalse(ApplicationUpdateCoordinator.isValidTransition(from: .downloading, to: .completed))
    }

    @MainActor
    func testStoreRejectsBufferedTaskAndSnapshotEventsFromStaleSession() {
        let application = AppUpdateTestFixtures.strictHomebrewApplication(id: "shared-application")
        let oldSessionID = UUID()
        let activeSessionID = UUID()
        let store = ScanStore()
        store.appUpdates = [application]

        var staleTask = ApplicationUpdateTask(
            sessionID: oldSessionID,
            application: application,
            state: .failed
        )
        staleTask.errorDescription = "stale failure"
        XCTAssertFalse(store.applyApplicationUpdateCoordinatorEvent(
            .taskChanged(staleTask),
            expectedSessionID: activeSessionID
        ))
        XCTAssertEqual(store.appUpdates.first?.updateStatus, application.updateStatus)

        let stalePlan = ApplicationUpdatePlanBuilder().build(
            applications: [application],
            id: oldSessionID
        )
        let staleSnapshot = ApplicationUpdateQueueSnapshot(
            schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion,
            plan: stalePlan,
            tasks: [staleTask],
            isPaused: false,
            updatedAt: Date()
        )
        XCTAssertFalse(store.applyApplicationUpdateCoordinatorEvent(
            .snapshotChanged(staleSnapshot),
            expectedSessionID: activeSessionID
        ))
        XCTAssertNil(store.appUpdateQueueSnapshot)

        var activeTask = ApplicationUpdateTask(
            sessionID: activeSessionID,
            application: application,
            state: .downloading
        )
        activeTask.detail = "active download"
        XCTAssertTrue(store.applyApplicationUpdateCoordinatorEvent(
            .taskChanged(activeTask),
            expectedSessionID: activeSessionID
        ))
        XCTAssertEqual(store.appUpdates.first?.updateStatus, .downloading)

        let activePlan = ApplicationUpdatePlanBuilder().build(
            applications: [application],
            id: activeSessionID
        )
        let activeSnapshot = ApplicationUpdateQueueSnapshot(
            schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion,
            plan: activePlan,
            tasks: [activeTask],
            isPaused: false,
            updatedAt: Date()
        )
        XCTAssertTrue(store.applyApplicationUpdateCoordinatorEvent(
            .snapshotChanged(activeSnapshot),
            expectedSessionID: activeSessionID
        ))
        XCTAssertEqual(store.appUpdateQueueSnapshot?.plan.id, activeSessionID)

        XCTAssertFalse(store.applyApplicationUpdateCoordinatorEvent(
            .persistenceFailed(sessionID: oldSessionID, detail: "stale persistence failure"),
            expectedSessionID: activeSessionID
        ))
        XCTAssertFalse(store.appUpdateScanWarnings.contains("stale persistence failure"))

        XCTAssertTrue(store.applyApplicationUpdateCoordinatorEvent(
            .persistenceFailed(sessionID: activeSessionID, detail: "active persistence failure"),
            expectedSessionID: activeSessionID
        ))
        XCTAssertTrue(store.appUpdateScanWarnings.contains("active persistence failure"))

        XCTAssertFalse(store.applyApplicationUpdateCoordinatorEvent(
            .persistenceFailed(sessionID: nil, detail: "unscoped recovery warning"),
            expectedSessionID: activeSessionID
        ))
        XCTAssertTrue(store.applyApplicationUpdateCoordinatorEvent(
            .persistenceFailed(sessionID: nil, detail: "recovery warning"),
            expectedSessionID: nil
        ))
    }

    @MainActor
    func testExecutionTimeWaitingStateMakesLaterTerminationEventRecoverable() {
        let sessionID = UUID()
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "late-running",
            token: "late-running",
            path: "/Applications/Late Running.app"
        )
        let store = ScanStore()
        store.appUpdates = [application]
        var task = ApplicationUpdateTask(
            sessionID: sessionID,
            application: application,
            state: .waitingForQuit
        )
        task.detail = "started after queueing"

        XCTAssertTrue(store.applyApplicationUpdateCoordinatorEvent(
            .taskChanged(task),
            expectedSessionID: sessionID
        ))
        XCTAssertTrue(store.appUpdates[0].isRunning)
        XCTAssertTrue(store.appUpdates[0].requiresApplicationQuit)

        let stoppedIDs = ScanStore.applicationIDsStoppedByTermination(
            applications: store.appUpdates,
            bundleIdentifier: application.bundleIdentifier,
            bundleURL: application.bundleURL,
            runningState: ApplicationRunningStateSnapshot(
                bundleIdentifiers: [],
                normalizedBundlePaths: []
            )
        )
        XCTAssertEqual(stoppedIDs, [application.id])
    }

    func testRefreshApplicationsResumesWaitingForQuitOnlyAfterSafeSignedAppStops() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ApplicationUpdateQueueRepository(
            fileURL: root.appendingPathComponent("queue.json")
        )
        let executor = ScriptedAppUpdateExecutor(
            outcomes: ["waiting": .success(ApplicationVersion(marketing: "2.0"))]
        )
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        let running = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "waiting",
            token: "waiting",
            path: "/Applications/Waiting.app",
            isRunning: true
        )

        let started = try await coordinator.start(applications: [running])
        XCTAssertEqual(started.tasks.first?.state, .waitingForQuit)
        let initialOrder = await executor.executionOrder()
        XCTAssertTrue(initialOrder.isEmpty)

        var unsignedStopped = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "waiting",
            token: "waiting",
            path: "/Applications/Waiting.app",
            isRunning: false
        )
        unsignedStopped.signingTeamIdentifier = nil
        let stillWaiting = try await coordinator.refreshApplications([unsignedStopped])
        XCTAssertEqual(stillWaiting?.tasks.first?.state, .waitingForQuit)
        let orderAfterUnsafeRefresh = await executor.executionOrder()
        XCTAssertTrue(orderAfterUnsafeRefresh.isEmpty)

        let safelyStopped = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "waiting",
            token: "waiting",
            path: "/Applications/Waiting.app",
            isRunning: false
        )
        let resumed = try await coordinator.refreshApplications([safelyStopped])
        XCTAssertEqual(resumed?.tasks.first?.state, .queued)

        let completed = try await waitForQueue(coordinator) {
            $0.tasks.first?.state == .completed
        }
        XCTAssertEqual(completed.tasks.first?.state, .completed)
        let finalOrder = await executor.executionOrder()
        XCTAssertEqual(finalOrder, ["waiting"])
    }

    func testQueueContinuesAfterOneItemFailsAndPersistsResults() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ApplicationUpdateQueueRepository(
            fileURL: root.appendingPathComponent("queue.json")
        )
        let executor = ScriptedAppUpdateExecutor(
            outcomes: [
                "success": .success(ApplicationVersion(marketing: "2.0")),
                "failure": .failure("fixture failure"),
                "after": .success(ApplicationVersion(marketing: "2.0")),
            ]
        )
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        let applications = [
            AppUpdateTestFixtures.strictHomebrewApplication(id: "success", token: "success"),
            AppUpdateTestFixtures.strictHomebrewApplication(id: "failure", token: "failure"),
            AppUpdateTestFixtures.strictHomebrewApplication(id: "after", token: "after"),
        ]

        _ = try await coordinator.start(applications: applications)
        let snapshot = try await waitForQueue(coordinator) {
            $0.tasks.allSatisfy(\.state.isTerminal)
        }
        let states = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.applicationID, $0.state) })

        XCTAssertEqual(states["success"], .completed)
        XCTAssertEqual(states["failure"], .failed)
        XCTAssertEqual(states["after"], .completed)
        let executionOrder = await executor.executionOrder()
        XCTAssertEqual(executionOrder, ["success", "failure", "after"])
        let maximumActiveExecutionCount = await executor.maximumActiveExecutionCountValue()
        XCTAssertEqual(maximumActiveExecutionCount, 1)

        let loaded = try await repository.load()
        let persisted = try XCTUnwrap(loaded)
        XCTAssertEqual(persisted.tasks.map(\.id), snapshot.tasks.map(\.id))
        XCTAssertEqual(persisted.tasks.map(\.applicationID), snapshot.tasks.map(\.applicationID))
        XCTAssertEqual(persisted.tasks.map(\.state), snapshot.tasks.map(\.state))
        XCTAssertEqual(persisted.tasks.map(\.attemptCount), snapshot.tasks.map(\.attemptCount))
        XCTAssertEqual(persisted.tasks.map(\.errorDescription), snapshot.tasks.map(\.errorDescription))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("queue.json").path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue ?? 0, 0o600)
    }

    func testRuntimePersistenceFailureRestoresByReconciliationWithoutReexecuting() async throws {
        let repository = FaultInjectingApplicationUpdateQueueRepository()
        await repository.configure(failSaveFromAttempt: 4)
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "durable-side-effect",
            token: "durable-side-effect"
        )
        let firstExecutor = ScriptedAppUpdateExecutor(
            outcomes: [
                application.id: .success(ApplicationVersion(marketing: "2.0")),
            ]
        )
        let firstCoordinator = ApplicationUpdateCoordinator(
            repository: repository,
            executor: firstExecutor
        )

        _ = try await firstCoordinator.start(applications: [application])
        _ = try await waitForQueue(firstCoordinator) { snapshot in
            snapshot.isPaused && snapshot.tasks.first?.state == .failed
        }
        let firstExecutionOrder = await firstExecutor.executionOrder()
        XCTAssertEqual(firstExecutionOrder, [application.id])
        let durableSnapshot = try await repository.load()
        // The durable state remains `installing` when the post-side-effect
        // save fails; restore maps that in-flight state to reconciliation.
        XCTAssertEqual(durableSnapshot?.tasks.first?.state, .installing)

        await repository.configure(failSave: false, failClear: false)
        let recoveryExecutor = ScriptedAppUpdateExecutor(
            outcomes: [
                application.id: .success(ApplicationVersion(marketing: "2.0")),
            ]
        )
        let recoveryCoordinator = ApplicationUpdateCoordinator(
            repository: repository,
            executor: recoveryExecutor
        )

        _ = try await recoveryCoordinator.restore(
            applications: [application],
            autoResume: true
        )
        let recovered = try await waitForQueue(recoveryCoordinator) {
            $0.tasks.first?.state == .completed
        }

        XCTAssertEqual(recovered.tasks.first?.state, .completed)
        let recoveryExecutionOrder = await recoveryExecutor.executionOrder()
        XCTAssertTrue(recoveryExecutionOrder.isEmpty)
    }

    func testQueuedItemsKeepClickTimeSnapshotWhenInventoryRefreshesDuringBatch() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ApplicationUpdateQueueRepository(
            fileURL: root.appendingPathComponent("queue.json")
        )
        let expectedVersion = ApplicationVersion(marketing: "2.0")
        let executor = ScriptedAppUpdateExecutor(
            outcomes: [
                "blocking": .waitForRelease(expectedVersion),
                "queued": .success(expectedVersion),
            ]
        )
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        let blocking = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "blocking",
            token: "blocking"
        )
        let queued = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "queued",
            token: "queued"
        )

        _ = try await coordinator.start(applications: [blocking, queued])
        _ = try await waitForQueue(coordinator) {
            $0.tasks.contains { $0.applicationID == "blocking" && $0.state == .installing }
        }

        var newerInventoryRecord = queued
        newerInventoryRecord.availableVersion = ApplicationVersion(marketing: "9.0")
        newerInventoryRecord.canAutomaticallyUpdate = false
        _ = try await coordinator.refreshApplications([newerInventoryRecord])

        await executor.release("blocking")
        _ = try await waitForQueue(coordinator) {
            $0.tasks.allSatisfy(\.state.isTerminal)
        }

        let executedApplications = await executor.executedApplications()
        let executedQueued = try XCTUnwrap(executedApplications.first { $0.id == "queued" })
        XCTAssertEqual(executedQueued.availableVersion, queued.availableVersion)
        XCTAssertTrue(executedQueued.canAutomaticallyUpdate)
    }

    func testQueueCancellationStopsActiveExecutorAndMarksRemainingItemsCancelled() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ApplicationUpdateQueueRepository(
            fileURL: root.appendingPathComponent("queue.json")
        )
        let executor = ScriptedAppUpdateExecutor(
            outcomes: [
                "blocking": .waitForCancellation,
                "never": .success(ApplicationVersion(marketing: "2.0")),
            ]
        )
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        let applications = [
            AppUpdateTestFixtures.strictHomebrewApplication(id: "blocking", token: "blocking"),
            AppUpdateTestFixtures.strictHomebrewApplication(id: "never", token: "never"),
        ]

        _ = try await coordinator.start(applications: applications)
        _ = try await waitForQueue(coordinator) {
            $0.tasks.contains { $0.applicationID == "blocking" && $0.state == .installing }
        }
        try await coordinator.cancel()
        let currentSnapshot = await coordinator.currentSnapshot()
        let snapshot = try XCTUnwrap(currentSnapshot)
        let cancelledApplicationIDs = await executor.cancelledApplicationIDs()
        let executionOrder = await executor.executionOrder()

        XCTAssertTrue(snapshot.tasks.allSatisfy { $0.state == .cancelled })
        XCTAssertTrue(cancelledApplicationIDs.contains("blocking"))
        XCTAssertFalse(executionOrder.contains("never"))
    }

    func testCancellationAfterFinalStartCheckCannotScheduleExecutor() async throws {
        let repository = FaultInjectingApplicationUpdateQueueRepository()
        let executor = ScriptedAppUpdateExecutor(
            outcomes: ["never": .success(ApplicationVersion(marketing: "2.0"))]
        )
        let scheduleGate = ApplicationUpdateWorkerScheduleGate()
        let coordinator = ApplicationUpdateCoordinator(
            repository: repository,
            executor: executor,
            beforeWorkerSchedule: { await scheduleGate.wait() }
        )
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "never",
            token: "never"
        )

        let start = Task {
            try await coordinator.start(applications: [application])
        }
        await scheduleGate.waitUntilStarted()
        start.cancel()
        await scheduleGate.open()

        do {
            _ = try await start.value
            XCTFail("Expected start cancellation")
        } catch is CancellationError {
            // The cancellation landed after the first check but before worker
            // creation; no provider execution may escape that window.
        }

        for _ in 0..<20 { await Task.yield() }
        let executionOrder = await executor.executionOrder()
        XCTAssertTrue(executionOrder.isEmpty)
        let persisted = try await repository.load()
        XCTAssertTrue(persisted?.tasks.allSatisfy { $0.state == .cancelled } == true)
    }

    func testExplicitCancellationClearsOldSnapshotWhenSavingCancelledStateFails() async throws {
        let repository = FaultInjectingApplicationUpdateQueueRepository()
        let executor = ScriptedAppUpdateExecutor(outcomes: ["blocking": .waitForCancellation])
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "blocking",
            token: "blocking"
        )

        _ = try await coordinator.start(applications: [application])
        _ = try await waitForQueue(coordinator) {
            $0.tasks.first?.state == .installing
        }
        await repository.configure(failSave: true, failClear: false)

        try await coordinator.cancel()

        let persisted = try await repository.load()
        let cancelledApplicationIDs = await executor.cancelledApplicationIDs()
        XCTAssertNil(persisted)
        XCTAssertEqual(cancelledApplicationIDs, [application.id])
        let current = await coordinator.currentSnapshot()
        XCTAssertTrue(current?.tasks.allSatisfy { $0.state == .cancelled } == true)
    }

    func testExplicitCancellationThrowsWhenSavingAndClearingSnapshotBothFail() async throws {
        let repository = FaultInjectingApplicationUpdateQueueRepository()
        let executor = ScriptedAppUpdateExecutor(outcomes: ["blocking": .waitForCancellation])
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        let application = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "blocking",
            token: "blocking"
        )

        _ = try await coordinator.start(applications: [application])
        _ = try await waitForQueue(coordinator) {
            $0.tasks.first?.state == .installing
        }
        await repository.configure(failSave: true, failClear: true)

        do {
            try await coordinator.cancel()
            XCTFail("Expected cancellation persistence to fail closed")
        } catch ApplicationUpdateCoordinatorError.cancellationPersistenceFailed {
            // Expected: physical work still stops, but the caller sees the
            // durable-state failure instead of a false cancellation success.
        }

        let cancelledApplicationIDs = await executor.cancelledApplicationIDs()
        XCTAssertEqual(cancelledApplicationIDs, [application.id])
        let current = await coordinator.currentSnapshot()
        XCTAssertTrue(current?.tasks.allSatisfy { $0.state == .cancelled } == true)
    }

    func testTerminationSuspendsAndResumesQueueWithoutUserCancellation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ApplicationUpdateQueueRepository(
            fileURL: root.appendingPathComponent("queue.json")
        )
        let executor = ScriptedAppUpdateExecutor(
            outcomes: [
                "blocking": .waitForCancellation,
                "after": .success(ApplicationVersion(marketing: "2.0")),
            ]
        )
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        let applications = [
            AppUpdateTestFixtures.strictHomebrewApplication(id: "blocking", token: "blocking"),
            AppUpdateTestFixtures.strictHomebrewApplication(id: "after", token: "after"),
        ]

        _ = try await coordinator.start(applications: applications)
        _ = try await waitForQueue(coordinator) {
            $0.tasks.contains { $0.applicationID == "blocking" && $0.state == .installing }
        }
        try await coordinator.suspendForTermination()

        let currentSnapshot = await coordinator.currentSnapshot()
        let suspended = try XCTUnwrap(currentSnapshot)
        let suspendedStates = Dictionary(
            uniqueKeysWithValues: suspended.tasks.map { ($0.applicationID, $0.state) }
        )
        XCTAssertTrue(suspended.isPaused)
        XCTAssertEqual(suspendedStates["blocking"], .needsReconciliation)
        XCTAssertEqual(suspendedStates["after"], .queued)
        XCTAssertFalse(suspended.tasks.contains { $0.state == .cancelled })
        let loadedSnapshot = try await repository.load()
        let persisted = try XCTUnwrap(loadedSnapshot)
        XCTAssertTrue(persisted.isPaused)
        XCTAssertEqual(
            persisted.tasks.first(where: { $0.applicationID == "blocking" })?.originalIdentity,
            applications[0].identity
        )

        await executor.setOutcome(.success(ApplicationVersion(marketing: "2.0")), for: "blocking")
        try await coordinator.resume()
        let completed = try await waitForQueue(coordinator) {
            $0.tasks.allSatisfy { $0.state == .completed }
        }
        XCTAssertFalse(completed.isPaused)
        let executionOrder = await executor.executionOrder()
        XCTAssertEqual(Set(executionOrder), ["blocking", "after"])
    }

    func testFailedTaskCanRetryWithoutCreatingANewSession() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ApplicationUpdateQueueRepository(
            fileURL: root.appendingPathComponent("queue.json")
        )
        let executor = ScriptedAppUpdateExecutor(outcomes: ["retry": .failure("first")])
        let coordinator = ApplicationUpdateCoordinator(repository: repository, executor: executor)
        let application = AppUpdateTestFixtures.strictHomebrewApplication(id: "retry", token: "retry")

        let started = try await coordinator.start(applications: [application])
        _ = try await waitForQueue(coordinator) {
            $0.tasks.first?.state == .failed
        }
        await executor.setOutcome(.success(ApplicationVersion(marketing: "2.0")), for: "retry")
        try await coordinator.retry(applicationID: "retry")
        let finished = try await waitForQueue(coordinator) {
            $0.tasks.first?.state == .completed
        }

        XCTAssertEqual(finished.plan.id, started.plan.id)
        XCTAssertEqual(finished.tasks.first?.attemptCount, 2)
    }

    func testRestoreMovesInterruptedInstallToNeedsReconciliation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ApplicationUpdateQueueRepository(
            fileURL: root.appendingPathComponent("queue.json")
        )
        let application = AppUpdateTestFixtures.strictHomebrewApplication(id: "interrupted")
        let plan = ApplicationUpdatePlanBuilder().build(
            applications: [application],
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        var task = ApplicationUpdateTask(
            sessionID: plan.id,
            application: application,
            state: .installing,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        task.attemptCount = 1
        let persisted = ApplicationUpdateQueueSnapshot(
            schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion,
            plan: plan,
            tasks: [task],
            isPaused: false,
            updatedAt: Date(timeIntervalSince1970: 101)
        )
        try await repository.save(persisted)
        let coordinator = ApplicationUpdateCoordinator(
            repository: repository,
            executor: UnsupportedApplicationUpdateExecutor(),
            now: { Date(timeIntervalSince1970: 200) }
        )

        let restoredValue = try await coordinator.restore(
            applications: [application],
            autoResume: false
        )
        let restored = try XCTUnwrap(restoredValue)

        XCTAssertTrue(restored.isPaused)
        XCTAssertEqual(restored.tasks.first?.state, .needsReconciliation)
        XCTAssertEqual(restored.tasks.first?.updatedAt, Date(timeIntervalSince1970: 200))
    }

    func testReconcileUsesPersistedOriginalVersionInsteadOfFreshScanVersion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try makeApplicationBundle(
            in: root,
            bundleIdentifier: "com.example.reconcile",
            version: "2.0",
            build: "200"
        )
        let original = AppUpdateTestFixtures.application(
            id: "reconcile",
            bundleIdentifier: "com.example.reconcile",
            path: appURL.path,
            version: "1.0",
            build: "100",
            availableVersion: "2.0",
            signingTeamIdentifier: "TEAM123",
            codeSigningIdentifier: "com.example.reconcile",
            installationSource: .homebrewCask,
            provider: .homebrew,
            status: .automaticallyUpdatable,
            sourceEvidence: ["homebrew-cli-json-v2", "homebrew-match:exact-artifact-path", "valid-code-signature"],
            homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(
                token: "reconcile",
                appBundlePaths: [appURL.path]
            ),
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )
        let task = ApplicationUpdateTask(sessionID: UUID(), application: original)
        var freshScan = original
        freshScan.installedVersion = ApplicationVersion(marketing: "2.0", build: "200")
        freshScan.buildNumber = "200"
        let executor = ProviderBackedApplicationUpdateExecutor(
            metadataReader: ApplicationMetadataReader(
                signatureInspector: FixedApplicationSignatureInspector(
                    teamIdentifier: "TEAM123",
                    codeSigningIdentifier: "com.example.reconcile"
                )
            ),
            heavyWorkCoordinator: HeavyWorkCoordinator()
        )

        let result = try await executor.reconcile(task: task, application: freshScan)

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.observedVersion, ApplicationVersion(marketing: "2.0", build: "200"))
    }

    func testOfficialReconcileRecoversNilApplicationAfterReplacementCrash() async throws {
        let fixture = try makeOfficialReplacementReconcileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try FileManager.default.moveItem(at: fixture.destination, to: fixture.backup)
        try FileManager.default.moveItem(at: fixture.staged, to: fixture.destination)
        try OfficialApplicationReplacementTransactionStore(fileURL: fixture.transactionURL).save(
            fixture.transaction(.destinationMovedToBackup)
        )

        let executor = makeOfficialReplacementExecutor(fixture: fixture)
        let result = try await executor.reconcile(task: fixture.task, application: nil)

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.observedVersion, fixture.targetVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.transactionURL.path))
    }

    func testOfficialReconcileRejectsTransactionIdentityOrTargetMismatchBeforeCleanup() async throws {
        let fixture = try makeOfficialReplacementReconcileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try FileManager.default.moveItem(at: fixture.destination, to: fixture.backup)
        try FileManager.default.moveItem(at: fixture.staged, to: fixture.destination)
        try OfficialApplicationReplacementTransactionStore(fileURL: fixture.transactionURL).save(
            fixture.transaction(.stagedMovedToDestination)
        )
        var mismatchedApplication = fixture.application
        mismatchedApplication.bundleIdentifier = "com.example.other"
        mismatchedApplication.codeSigningIdentifier = "com.example.other"
        let mismatchedTask = ApplicationUpdateTask(
            sessionID: UUID(),
            application: mismatchedApplication
        )
        let executor = makeOfficialReplacementExecutor(fixture: fixture)

        do {
            _ = try await executor.reconcile(task: mismatchedTask, application: nil)
            XCTFail("Expected identity mismatch to fail closed")
        } catch ProviderBackedUpdateExecutorError.replacementRecoveryFailed {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.transactionURL.path))
        }
    }

    func testFormulaReconciliationQueriesOnlyThePlannedHomebrewToken() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let brew = bin.appendingPathComponent("brew", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: brew.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: brew.path
        )
        let runner = FormulaVerificationCommandRunner(response: Data(#"""
        {
          "formulae": [{
            "name": "example",
            "full_name": "example",
            "installed": [{"version": "2.0"}]
          }]
        }
        """#.utf8))
        let scanner = HomebrewInventoryScanner(
            runner: runner,
            environmentProvider: {
                [
                    "HOMEBREW_PREFIX": root.path,
                    "HOMEBREW_BREW_FILE": brew.path,
                ]
            }
        )
        var formula = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "formula",
            token: "example",
            path: root.appendingPathComponent("Cellar/example", isDirectory: true).path
        )
        formula.installationSource = .homebrewFormula
        formula.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(
            token: "example",
            kind: .formula,
            appBundlePaths: []
        )
        formula.caskToken = nil
        let task = ApplicationUpdateTask(sessionID: UUID(), application: formula)
        let executor = ProviderBackedApplicationUpdateExecutor(
            homebrewScanner: scanner,
            heavyWorkCoordinator: HeavyWorkCoordinator()
        )

        let result = try await executor.reconcile(task: task, application: formula)

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.observedVersion, ApplicationVersion(marketing: "2.0"))
        let arguments = await runner.recordedArguments()
        XCTAssertEqual(arguments, [["info", "--json=v2", "--formula", "example"]])
    }

    func testReconcileRejectsChangedVersionBelowFrozenTarget() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let brew = bin.appendingPathComponent("brew", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: brew.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: brew.path
        )
        let runner = FormulaVerificationCommandRunner(response: Data(#"""
        {
          "formulae": [{
            "name": "example",
            "full_name": "example",
            "installed": [{"version": "1.5"}]
          }]
        }
        """#.utf8))
        let scanner = HomebrewInventoryScanner(
            runner: runner,
            environmentProvider: {
                [
                    "HOMEBREW_PREFIX": root.path,
                    "HOMEBREW_BREW_FILE": brew.path,
                ]
            }
        )
        var formula = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "formula-below-target",
            token: "example",
            path: root.appendingPathComponent("Cellar/example", isDirectory: true).path
        )
        formula.installationSource = .homebrewFormula
        formula.homebrewMetadata = AppUpdateTestFixtures.homebrewMetadata(
            token: "example",
            kind: .formula,
            appBundlePaths: []
        )
        formula.caskToken = nil
        let task = ApplicationUpdateTask(sessionID: UUID(), application: formula)
        let executor = ProviderBackedApplicationUpdateExecutor(
            homebrewScanner: scanner,
            heavyWorkCoordinator: HeavyWorkCoordinator()
        )

        do {
            _ = try await executor.reconcile(task: task, application: formula)
            XCTFail("Expected a version below the frozen target to fail closed")
        } catch let ProviderBackedUpdateExecutorError.targetVersionNotReached(expected, observed) {
            XCTAssertEqual(expected, ApplicationVersion(marketing: "2.0"))
            XCTAssertEqual(observed, ApplicationVersion(marketing: "1.5"))
        }
    }

    func testReconcileRejectsChangedOnDiskSigningIdentity() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try makeApplicationBundle(
            in: root,
            bundleIdentifier: "com.example.identity",
            version: "2.0",
            build: "200"
        )
        let original = AppUpdateTestFixtures.application(
            id: "identity",
            bundleIdentifier: "com.example.identity",
            path: appURL.path,
            version: "1.0",
            build: "100",
            availableVersion: "2.0",
            signingTeamIdentifier: "TEAM123",
            codeSigningIdentifier: "com.example.identity",
            installationSource: .homebrewCask,
            provider: .homebrew,
            status: .automaticallyUpdatable,
            sourceEvidence: ["homebrew-cli-json-v2", "homebrew-match:exact-artifact-path", "valid-code-signature"],
            homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(
                token: "identity",
                appBundlePaths: [appURL.path]
            ),
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )
        let task = ApplicationUpdateTask(sessionID: UUID(), application: original)
        var freshScan = original
        freshScan.installedVersion = ApplicationVersion(marketing: "2.0", build: "200")
        freshScan.buildNumber = "200"
        let executor = ProviderBackedApplicationUpdateExecutor(
            metadataReader: ApplicationMetadataReader(
                signatureInspector: FixedApplicationSignatureInspector(
                    teamIdentifier: "OTHERTEAM",
                    codeSigningIdentifier: "com.example.identity"
                )
            ),
            heavyWorkCoordinator: HeavyWorkCoordinator()
        )

        do {
            _ = try await executor.reconcile(task: task, application: freshScan)
            XCTFail("Expected changed signing identity to fail closed")
        } catch ProviderBackedUpdateExecutorError.applicationIdentityChanged {
            // Expected.
        }
    }

    func testRepositoryRejectsUnsupportedSchema() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ApplicationUpdateQueueRepository(
            fileURL: root.appendingPathComponent("queue.json")
        )
        let plan = ApplicationUpdatePlan(
            automaticApplicationIDs: [],
            requiresQuitApplicationIDs: [],
            requiresAuthorizationApplicationIDs: [],
            appStoreApplicationIDs: [],
            websiteApplicationIDs: [],
            manualApplicationIDs: [],
            skippedApplicationIDs: []
        )
        let snapshot = ApplicationUpdateQueueSnapshot(
            schemaVersion: 999,
            plan: plan,
            tasks: [],
            isPaused: false,
            updatedAt: Date()
        )

        do {
            try await repository.save(snapshot)
            XCTFail("Expected unsupported schema error")
        } catch {
            guard case .unsupportedSchema(999) = error as? ApplicationUpdateQueueRepositoryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private struct OfficialReplacementReconcileFixture {
        let root: URL
        let destination: URL
        let backup: URL
        let staged: URL
        let transactionURL: URL
        let application: InstalledApplication
        let task: ApplicationUpdateTask
        let identity: ApplicationIdentity
        let originalVersion: ApplicationVersion
        let targetVersion: ApplicationVersion
        let transaction: (OfficialApplicationReplacementPhase) -> OfficialApplicationReplacementTransaction
        let identityVerifier: OfficialApplicationReplacement.IdentityVerifier
    }

    private func makeOfficialReplacementReconcileFixture() throws -> OfficialReplacementReconcileFixture {
        let root = try makeTemporaryDirectory()
        let destination = try makeApplicationBundle(
            in: root,
            bundleIdentifier: "com.example.official",
            version: "1.0",
            build: "100"
        )
        let staged = root.appendingPathComponent(
            ".StorageCleanerMac-Update-\(UUID().uuidString).app",
            isDirectory: true
        )
        let candidate = try makeApplicationBundle(
            in: root,
            bundleIdentifier: "com.example.official",
            version: "2.0",
            build: "200"
        )
        try FileManager.default.moveItem(at: candidate, to: staged)
        let backup = root.appendingPathComponent(
            ".StorageCleanerMac-Backup-\(UUID().uuidString).app",
            isDirectory: true
        )
        let transactionURL = root.appendingPathComponent("replacement.json")
        let originalVersion = ApplicationVersion(marketing: "1.0", build: "100")
        let targetVersion = ApplicationVersion(marketing: "2.0", build: "200")
        let bundleIdentifier = "com.example.official"
        let applicationID = "\(bundleIdentifier)|\(ApplicationPathNormalizer.normalizedPath(for: destination))"
        var application = AppUpdateTestFixtures.application(
            id: applicationID,
            bundleIdentifier: bundleIdentifier,
            path: destination.path,
            version: originalVersion.marketing,
            build: originalVersion.build,
            availableVersion: targetVersion.marketing,
            signingTeamIdentifier: "TEAM123",
            codeSigningIdentifier: bundleIdentifier,
            provider: .officialWebsite,
            status: .automaticallyUpdatable,
            sourceEvidence: ["valid-code-signature"],
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )
        application.availableVersion = targetVersion
        let task = ApplicationUpdateTask(sessionID: UUID(), application: application)
        let identity = application.identity
        let transactionID = UUID()
        let transaction = { phase in
            OfficialApplicationReplacementTransaction(
                id: transactionID,
                rootURL: root,
                destinationURL: destination,
                backupURL: backup,
                stagedURL: staged,
                expectedIdentity: identity,
                originalVersion: originalVersion,
                targetVersion: targetVersion,
                phase: phase
            )
        }
        let identityVerifier: OfficialApplicationReplacement.IdentityVerifier = { url, expected in
            Bundle(url: url)?.bundleIdentifier == expected.bundleIdentifier
        }
        return OfficialReplacementReconcileFixture(
            root: root,
            destination: destination,
            backup: backup,
            staged: staged,
            transactionURL: transactionURL,
            application: application,
            task: task,
            identity: identity,
            originalVersion: originalVersion,
            targetVersion: targetVersion,
            transaction: transaction,
            identityVerifier: identityVerifier
        )
    }

    private func makeOfficialReplacementExecutor(
        fixture: OfficialReplacementReconcileFixture
    ) -> ProviderBackedApplicationUpdateExecutor {
        ProviderBackedApplicationUpdateExecutor(
            metadataReader: ApplicationMetadataReader(
                signatureInspector: FixedApplicationSignatureInspector(
                    teamIdentifier: "TEAM123",
                    codeSigningIdentifier: fixture.identity.bundleIdentifier
                )
            ),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            replacementTransactionURL: fixture.transactionURL,
            replacementIdentityVerifier: fixture.identityVerifier
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdateCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApplicationBundle(
        in root: URL,
        bundleIdentifier: String,
        version: String,
        build: String
    ) throws -> URL {
        let appURL = root.appendingPathComponent("Fixture-\(UUID().uuidString).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executableDirectory,
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Fixture",
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
        try Data("fixture".utf8).write(
            to: executableDirectory.appendingPathComponent("Fixture"),
            options: .atomic
        )
        return appURL
    }
}

private struct FixedApplicationSignatureInspector: ApplicationCodeSignatureInspecting {
    let teamIdentifier: String?
    let codeSigningIdentifier: String?

    func inspectSignature(at applicationURL: URL) async -> ApplicationCodeSignatureMetadata {
        ApplicationCodeSignatureMetadata(
            signingTeamIdentifier: teamIdentifier,
            codeSigningIdentifier: codeSigningIdentifier,
            isValid: true
        )
    }
}

private actor SuccessfulApplicationUpdateProvider: ApplicationUpdateProvider {
    let identifier = ApplicationUpdateProviderIdentifier.homebrew
    let applicationURL: URL
    let targetVersion: ApplicationVersion
    private(set) var prepareCallCount = 0
    private(set) var installCallCount = 0

    init(applicationURL: URL, targetVersion: ApplicationVersion) {
        self.applicationURL = applicationURL
        self.targetVersion = targetVersion
    }

    func canHandle(_ application: InstalledApplication) async -> Bool {
        application.updateProvider == identifier
    }

    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        ApplicationUpdateSourceInfo(
            providerIdentifier: identifier,
            evidence: ["fixture-provider"],
            requiresUserInteraction: false,
            canAutomaticallyUpdate: true
        )
    }

    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult {
        ApplicationUpdateCheckResult(
            status: .automaticallyUpdatable,
            availableVersion: targetVersion,
            releaseDate: nil,
            releaseNotes: nil,
            downloadSize: nil,
            warning: nil
        )
    }

    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate {
        prepareCallCount += 1
        return PreparedApplicationUpdate(
            applicationID: application.id,
            providerIdentifier: identifier,
            originalIdentity: application.identity,
            originalVersion: application.installedVersion,
            targetVersion: targetVersion,
            providerPayload: ["fixture": "true"]
        )
    }

    func install(
        _ preparedUpdate: PreparedApplicationUpdate,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        installCallCount += 1
        let infoURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard var plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL),
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw FixtureApplicationUpdateProviderError.invalidInfoPlist
        }
        plist["CFBundleShortVersionString"] = targetVersion.marketing
        plist["CFBundleVersion"] = targetVersion.build
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: infoURL, options: .atomic)
        progress(ApplicationUpdateProgressEvent(
            applicationID: preparedUpdate.applicationID,
            state: .installing,
            fraction: 1,
            detail: "fixture installed"
        ))
        return ApplicationUpdateInstallResult(
            applicationID: preparedUpdate.applicationID,
            state: .needsReconciliation,
            observedVersion: nil,
            detail: "fixture install requires reconciliation"
        )
    }
}

private enum FixtureApplicationUpdateProviderError: Error {
    case invalidInfoPlist
}

private enum FaultInjectingApplicationUpdateQueueRepositoryError: Error {
    case saveFailed
    case clearFailed
}

private actor FaultInjectingApplicationUpdateQueueRepository: ApplicationUpdateQueuePersisting {
    private var snapshot: ApplicationUpdateQueueSnapshot?
    private var failSave = false
    private var failClear = false
    private var failSaveFromAttempt: Int?
    private var saveAttemptCount = 0

    func configure(failSave: Bool, failClear: Bool) {
        self.failSave = failSave
        self.failClear = failClear
        failSaveFromAttempt = nil
    }

    func configure(failSaveFromAttempt: Int?) {
        failSave = false
        failClear = false
        self.failSaveFromAttempt = failSaveFromAttempt
    }

    func load() throws -> ApplicationUpdateQueueSnapshot? {
        snapshot
    }

    func save(_ snapshot: ApplicationUpdateQueueSnapshot) throws {
        saveAttemptCount += 1
        guard !failSave,
              failSaveFromAttempt.map({ saveAttemptCount < $0 }) ?? true else {
            throw FaultInjectingApplicationUpdateQueueRepositoryError.saveFailed
        }
        self.snapshot = snapshot
    }

    func clear() throws {
        guard !failClear else {
            throw FaultInjectingApplicationUpdateQueueRepositoryError.clearFailed
        }
        snapshot = nil
    }
}

private actor ApplicationUpdateWorkerScheduleGate {
    private var started = false
    private var isOpen = false
    private var startWaiters = [CheckedContinuation<Void, Never>]()
    private var openWaiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if isOpen { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private enum ScriptedAppUpdateOutcome: Sendable {
    case success(ApplicationVersion)
    case failure(String)
    case waitForCancellation
    case waitForRelease(ApplicationVersion)
}

private enum ScriptedAppUpdateError: Error {
    case expected(String)
}

private actor FormulaVerificationCommandRunner: HomebrewCommandRunning {
    private let response: Data
    private var arguments: [[String]] = []

    init(response: Data) {
        self.response = response
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        self.arguments.append(arguments)
        return response
    }

    func recordedArguments() -> [[String]] { arguments }
}

private actor ScriptedAppUpdateExecutor: ApplicationUpdateExecuting {
    private var outcomes: [String: ScriptedAppUpdateOutcome]
    private var executed: [String] = []
    private var executedApplicationSnapshots: [InstalledApplication] = []
    private var cancelled: Set<String> = []
    private var released: Set<String> = []
    private var activeExecutionCount = 0
    private var maximumActiveExecutionCount = 0

    init(outcomes: [String: ScriptedAppUpdateOutcome]) {
        self.outcomes = outcomes
    }

    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        activeExecutionCount += 1
        maximumActiveExecutionCount = max(
            maximumActiveExecutionCount,
            activeExecutionCount
        )
        defer { activeExecutionCount -= 1 }
        executed.append(application.id)
        executedApplicationSnapshots.append(application)
        await progress(
            ApplicationUpdateProgressEvent(
                applicationID: application.id,
                state: .installing,
                fraction: 0.5,
                detail: "fixture installing"
            )
        )
        switch outcomes[application.id] ?? .failure("missing fixture") {
        case let .success(version):
            return ApplicationUpdateInstallResult(
                applicationID: application.id,
                state: .completed,
                observedVersion: version,
                detail: "fixture verified"
            )
        case let .failure(detail):
            throw ScriptedAppUpdateError.expected(detail)
        case .waitForCancellation:
            while !cancelled.contains(application.id) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()
        case let .waitForRelease(version):
            while !released.contains(application.id) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            return ApplicationUpdateInstallResult(
                applicationID: application.id,
                state: .completed,
                observedVersion: version,
                detail: "fixture released and verified"
            )
        }
    }

    func cancel(applicationID: String) async {
        cancelled.insert(applicationID)
    }

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult {
        switch outcomes[task.applicationID] ?? .failure("fixture reconciliation unavailable") {
        case let .success(version):
            return ApplicationUpdateInstallResult(
                applicationID: task.applicationID,
                state: .completed,
                observedVersion: version,
                detail: "fixture reconciled"
            )
        case let .failure(detail):
            throw ScriptedAppUpdateError.expected(detail)
        case .waitForCancellation:
            throw CancellationError()
        case let .waitForRelease(version):
            return ApplicationUpdateInstallResult(
                applicationID: task.applicationID,
                state: .completed,
                observedVersion: version,
                detail: "fixture reconciliation released"
            )
        }
    }

    func setOutcome(_ outcome: ScriptedAppUpdateOutcome, for applicationID: String) {
        outcomes[applicationID] = outcome
    }

    func release(_ applicationID: String) {
        released.insert(applicationID)
    }

    func executionOrder() -> [String] { executed }
    func executedApplications() -> [InstalledApplication] { executedApplicationSnapshots }
    func cancelledApplicationIDs() -> Set<String> { cancelled }
    func maximumActiveExecutionCountValue() -> Int { maximumActiveExecutionCount }
}

private func waitForQueue(
    _ coordinator: ApplicationUpdateCoordinator,
    timeout: Duration = .seconds(3),
    predicate: @escaping @Sendable (ApplicationUpdateQueueSnapshot) -> Bool
) async throws -> ApplicationUpdateQueueSnapshot {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if let snapshot = await coordinator.currentSnapshot(), predicate(snapshot) {
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AppUpdateTestTimeout.timedOut
}

private enum AppUpdateTestTimeout: Error {
    case timedOut
}

@MainActor
private final class GracefulQuitRecorder {
    private let result: Bool
    private(set) var terminateCount = 0
    private(set) var forceTerminateCount = 0

    init(result: Bool) {
        self.result = result
    }

    func terminate() -> Bool {
        terminateCount += 1
        return result
    }

    func forceTerminate() -> Bool {
        forceTerminateCount += 1
        return true
    }
}

@MainActor
private func waitForMainActorCondition(
    timeout: Duration = .seconds(3),
    predicate: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AppUpdateTestTimeout.timedOut
}
