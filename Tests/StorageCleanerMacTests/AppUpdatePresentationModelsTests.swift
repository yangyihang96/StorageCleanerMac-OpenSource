import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdatePresentationModelsTests: XCTestCase {
    func testQueueSnapshotProjectsOneClickLifecycleWithoutASecondCoordinator() {
        let application = AppUpdateTestFixtures.application(
            id: "orchestrator",
            availableVersion: "2.0",
            provider: .homebrew,
            status: .automaticallyUpdatable
        )
        let sessionID = UUID()
        let plan = ApplicationUpdatePlan(
            automaticApplicationIDs: [application.id],
            requiresQuitApplicationIDs: [],
            requiresAuthorizationApplicationIDs: [],
            appStoreApplicationIDs: [],
            websiteApplicationIDs: [],
            manualApplicationIDs: [],
            skippedApplicationIDs: []
        )
        var snapshot = ApplicationUpdateQueueSnapshot(
            schemaVersion: 2,
            plan: plan,
            tasks: [ApplicationUpdateTask(sessionID: sessionID, application: application)],
            isPaused: false,
            updatedAt: Date()
        )

        XCTAssertEqual(snapshot.orchestratorState, UpdateOrchestratorState.preparing)
        snapshot.tasks[0].state = ApplicationUpdateTaskState.downloading
        XCTAssertEqual(snapshot.orchestratorState, UpdateOrchestratorState.downloading)
        snapshot.tasks[0].state = ApplicationUpdateTaskState.completed
        XCTAssertEqual(snapshot.orchestratorState, UpdateOrchestratorState.completed)
    }

    func testQueueProjectionKeepsActiveWorkAheadOfTerminalFailures() {
        let first = AppUpdateTestFixtures.strictHomebrewApplication(id: "first")
        let second = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "second",
            token: "second",
            path: "/Applications/Second.app"
        )

        XCTAssertEqual(
            queue(applications: [first, second], states: []).orchestratorState,
            .idle
        )
        XCTAssertEqual(
            queue(applications: [first, second], states: [.failed, .downloading]).orchestratorState,
            .downloading
        )
        XCTAssertEqual(
            queue(applications: [first, second], states: [.completed, .failed]).orchestratorState,
            .partialFailure
        )
        XCTAssertEqual(
            queue(applications: [first, second], states: [.failed, .failed]).orchestratorState,
            .failed
        )
        XCTAssertEqual(
            queue(applications: [first, second], states: [.completed, .cancelled]).orchestratorState,
            .cancelled
        )
    }

    func testQueueProjectionUsesWaitingInstallingAndVerifyingStates() {
        let first = AppUpdateTestFixtures.strictHomebrewApplication(id: "first")
        let second = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "second",
            token: "second",
            path: "/Applications/Second.app"
        )

        XCTAssertEqual(
            queue(applications: [first, second], states: [.waitingForQuit, .failed]).orchestratorState,
            .waitingForApplications
        )
        XCTAssertEqual(
            queue(applications: [first, second], states: [.installing, .failed]).orchestratorState,
            .installing
        )
        XCTAssertEqual(
            queue(applications: [first, second], states: [.verifying, .failed]).orchestratorState,
            .verifying
        )
    }

    func testInventoryScanStateIsExplicitWhenQueueIsEmpty() {
        let progress = AppScanProgressSnapshot(
            sessionID: UUID(),
            generatedAt: Date(),
            stage: .discoveringApplications,
            completedUnitCount: 0,
            totalUnitCount: nil,
            currentApplicationID: nil,
            currentApplicationName: nil
        )

        XCTAssertEqual(
            UpdateOrchestratorState.project(
                scanState: .scanning(progress),
                queue: nil,
                presentationSessionID: progress.sessionID
            ),
            .scanning
        )
        XCTAssertEqual(
            UpdateOrchestratorState.project(
                scanState: .idle,
                queue: nil,
                presentationSessionID: nil
            ),
            .idle
        )
    }

    func testFreshScanDoesNotProjectATerminalQueueFromAnOlderSession() {
        let application = AppUpdateTestFixtures.strictHomebrewApplication(id: "terminal")
        var terminalQueue = queue(applications: [application], states: [.completed])
        let freshScanSessionID = UUID()

        XCTAssertEqual(
            UpdateOrchestratorState.project(
                scanState: .ready,
                queue: terminalQueue,
                presentationSessionID: freshScanSessionID
            ),
            .idle
        )
        XCTAssertEqual(
            UpdateOrchestratorState.project(
                scanState: .ready,
                queue: terminalQueue,
                presentationSessionID: terminalQueue.plan.id
            ),
            .completed
        )

        terminalQueue.tasks[0].state = .downloading
        XCTAssertEqual(
            UpdateOrchestratorState.project(
                scanState: .ready,
                queue: terminalQueue,
                presentationSessionID: freshScanSessionID
            ),
            .downloading
        )
    }

    func testSummaryUsesStrictAutomaticEligibilityAndExcludesSystemManagedApps() {
        let sessionID = UUID()
        let automatic = AppUpdateTestFixtures.strictHomebrewApplication(id: "automatic")
        let manual = AppUpdateTestFixtures.application(
            id: "manual",
            provider: .macAppStore,
            status: .appStoreManaged,
            requiresUserInteraction: true
        )
        let current = AppUpdateTestFixtures.application(
            id: "current",
            provider: .manual,
            status: .upToDate
        )
        var unknown = AppUpdateTestFixtures.application(id: "unknown")
        unknown.updateCapability = .unavailable
        let system = AppUpdateTestFixtures.application(
            id: "system",
            path: "/System/Applications/System Settings.app",
            provider: .systemManaged,
            status: .systemManaged,
            isSystem: true
        )
        let summary = AppScanSummary(
            sessionID: sessionID,
            applications: [automatic, manual, current, unknown, system]
        )

        XCTAssertEqual(summary.scannedCount, 5)
        XCTAssertEqual(summary.eligibleAutomaticApps.map(\.id), ["automatic"])
        XCTAssertEqual(summary.automaticCount, 1)
        XCTAssertEqual(summary.manualCount, 1)
        XCTAssertEqual(summary.currentCount, 1)
        XCTAssertEqual(summary.unknownCount, 1)
        XCTAssertEqual(summary.systemManagedCount, 1)
        XCTAssertEqual(
            summary.automaticCount
                + summary.requiresQuitCount
                + summary.requiresAuthorizationCount
                + summary.manualCount
                + summary.currentCount
                + summary.unknownCount
                + summary.systemManagedCount,
            summary.scannedCount
        )
    }

    func testSummaryAndCatalogKeepAutomaticQuitAndAuthorizationDistinct() {
        let automatic = AppUpdateTestFixtures.strictHomebrewApplication(id: "automatic")
        let requiresQuit = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "requires-quit",
            token: "requires-quit",
            path: "/Applications/Requires Quit.app",
            isRunning: true
        )
        let requiresAuthorization = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "requires-authorization",
            token: "requires-authorization",
            path: "/Applications/Requires Authorization.app",
            requiresAuthorization: true
        )
        let summary = AppScanSummary(
            sessionID: UUID(),
            applications: [automatic, requiresQuit, requiresAuthorization]
        )
        let catalog = AppUpdateCatalogSnapshot(summary: summary)

        XCTAssertEqual(summary.eligibleAutomaticApps.map(\.id), ["automatic"])
        XCTAssertEqual(summary.requiresQuitApps.map(\.id), ["requires-quit"])
        XCTAssertEqual(
            summary.requiresAuthorizationApps.map(\.id),
            ["requires-authorization"]
        )
        XCTAssertEqual(
            summary.batchEligibleApps.map(\.id),
            ["automatic", "requires-quit"]
        )
        XCTAssertEqual(summary.automaticCount, 1)
        XCTAssertEqual(summary.requiresQuitCount, 1)
        XCTAssertEqual(summary.requiresAuthorizationCount, 1)
        XCTAssertEqual(summary.manualCount, 0)
        XCTAssertEqual(catalog.entries(matching: .automatic).map(\.id), ["automatic"])
        XCTAssertEqual(catalog.entries(matching: .requiresQuit).map(\.id), ["requires-quit"])
        XCTAssertEqual(
            catalog.entries(matching: .requiresAuthorization).map(\.id),
            ["requires-authorization"]
        )
        XCTAssertEqual(
            Set(catalog.entries.filter(\.canJoinAutomaticUpdateBatch).map(\.id)),
            Set(["automatic", "requires-quit"])
        )
        XCTAssertFalse(
            catalog.entries.first { $0.id == "requires-authorization" }?
                .canJoinAutomaticUpdateBatch ?? true
        )
    }

    func testCompletionStateOnlyCallsUnambiguousInventoryCurrent() {
        let current = AppUpdateTestFixtures.application(
            id: "current",
            status: .upToDate
        )
        let unknown = AppUpdateTestFixtures.application(id: "unknown")
        let manualAmbiguity = AppUpdateTestFixtures.application(
            id: "manual",
            availableVersion: "2.0",
            provider: .manual,
            status: .updateAvailable
        )
        let confirmedUpdate = AppUpdateTestFixtures.strictHomebrewApplication(id: "automatic")

        XCTAssertEqual(
            AppScanSummary(sessionID: UUID(), applications: [current]).completionState,
            .allCurrent
        )
        XCTAssertEqual(
            AppScanSummary(sessionID: UUID(), applications: []).completionState,
            .noConfirmedUpdates
        )
        XCTAssertEqual(
            AppScanSummary(sessionID: UUID(), applications: [unknown]).completionState,
            .noConfirmedUpdates
        )
        XCTAssertEqual(
            AppScanSummary(sessionID: UUID(), applications: [manualAmbiguity]).completionState,
            .noConfirmedUpdates
        )
        XCTAssertEqual(
            AppScanSummary(sessionID: UUID(), applications: [confirmedUpdate]).completionState,
            .updatesAvailable
        )
    }

    func testCatalogContainsOnlyConfirmedUpdatesAndKeepsProviderFilters() {
        let automatic = AppUpdateTestFixtures.strictHomebrewApplication(id: "automatic")
        let appStore = AppUpdateTestFixtures.application(
            id: "app-store",
            availableVersion: "2.0",
            provider: .macAppStore,
            status: .updateAvailable,
            sourceEvidence: ["verified-app-store-receipt"]
        )
        let inApp = AppUpdateTestFixtures.application(
            id: "in-app",
            availableVersion: "2.0",
            provider: .sparkle,
            status: .updateAvailable,
            sourceEvidence: ["sparkle-framework", "sparkle-feed"]
        )
        var website = AppUpdateTestFixtures.application(
            id: "website",
            availableVersion: "2.0",
            provider: .officialWebsite,
            status: .websiteUpdateRequired
        )
        website.officialSource = confirmedOfficialSource(for: website)
        let manualHomebrew = AppUpdateTestFixtures.application(
            id: "manual-homebrew",
            availableVersion: "2.0",
            provider: .homebrew,
            status: .updateAvailable,
            sourceEvidence: ["homebrew-cli-json-v2"],
            homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(),
            canAutomaticallyUpdate: false,
            requiresUserInteraction: true
        )
        let untrusted = AppUpdateTestFixtures.application(
            id: "untrusted",
            availableVersion: "2.0",
            provider: .manual,
            status: .updateAvailable
        )
        let current = AppUpdateTestFixtures.application(
            id: "current",
            availableVersion: "1.0",
            provider: .macAppStore,
            status: .upToDate,
            sourceEvidence: ["verified-app-store-receipt"]
        )
        var unknown = AppUpdateTestFixtures.application(id: "unknown")
        unknown.updateCapability = .unavailable
        let system = AppUpdateTestFixtures.application(
            id: "system",
            provider: .systemManaged,
            status: .systemManaged,
            isSystem: true
        )
        var duplicate = AppUpdateTestFixtures.strictHomebrewApplication(id: "duplicate")
        duplicate.isDuplicate = true
        let catalog = AppUpdateCatalogSnapshot(
            sessionID: UUID(),
            applications: [
                automatic, appStore, inApp, website, manualHomebrew,
                untrusted, current, unknown, system, duplicate,
            ]
        )

        XCTAssertEqual(
            catalog.entries(matching: .all).map(\.id),
            ["automatic", "app-store", "in-app", "website", "manual-homebrew"]
        )
        XCTAssertEqual(catalog.entries(matching: .automatic).map(\.id), ["automatic"])
        XCTAssertEqual(catalog.entries(matching: .appStore).map(\.id), ["app-store"])
        XCTAssertEqual(catalog.entries(matching: .inApplication).map(\.id), ["in-app"])
        XCTAssertEqual(catalog.entries(matching: .website).map(\.id), ["website"])
        XCTAssertEqual(catalog.entries(matching: .manual).map(\.id), ["manual-homebrew"])
        XCTAssertTrue(catalog.entries(matching: .unknown).isEmpty)
    }

    func testCatalogSurfacesInApplicationPathsWithoutClaimingUpdates() {
        // Sparkle app whose read-only probe could not confirm the remote
        // version: the in-app path must stay visible and honest.
        let sparkleUnknown = AppUpdateTestFixtures.application(
            id: "sparkle-unknown",
            provider: .sparkle,
            status: .latestVersionUnknown,
            sourceEvidence: ["sparkle-framework", "sparkle-feed"]
        )
        let vendor = AppUpdateTestFixtures.application(
            id: "vendor",
            provider: .vendorUpdater,
            status: .latestVersionUnknown,
            sourceEvidence: ["vendor-keystone"]
        )
        // Fallback apps without any updater evidence stay out of the catalog.
        let manualUnknown = AppUpdateTestFixtures.application(id: "manual-unknown")
        var sparkleSystem = AppUpdateTestFixtures.application(
            id: "sparkle-system",
            provider: .sparkle,
            status: .latestVersionUnknown,
            sourceEvidence: ["sparkle-framework"],
            isSystem: true
        )
        sparkleSystem.updateCapability = .inApplication

        let catalog = AppUpdateCatalogSnapshot(
            sessionID: UUID(),
            applications: [sparkleUnknown, vendor, manualUnknown, sparkleSystem]
        )

        XCTAssertEqual(
            Set(catalog.entries.map(\.id)),
            Set(["sparkle-unknown", "vendor"])
        )
        XCTAssertEqual(
            Set(catalog.entries(matching: .inApplication).map(\.id)),
            Set(["sparkle-unknown", "vendor"])
        )
        for entry in catalog.entries {
            XCTAssertEqual(entry.category, .inApplication, entry.id)
            XCTAssertFalse(entry.isUpdateAvailable, entry.id)
            XCTAssertFalse(entry.canJoinAutomaticUpdateBatch, entry.id)
            XCTAssertEqual(
                entry.application.updateHandlingTitle,
                L10n.text("请在应用内检查", "Check in the App"),
                entry.id
            )
        }
    }

    func testFrozenUpdatePlanPreservesEveryBucketAndSkipsUnsupportedExecution() {
        let automatic = AppUpdateTestFixtures.strictHomebrewApplication(id: "automatic")
        let waitingForQuit = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "waiting-for-quit",
            token: "waiting-for-quit",
            path: "/Applications/Waiting for Quit.app",
            isRunning: true
        )
        let authorization = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "authorization",
            token: "authorization",
            path: "/Applications/Authorization.app",
            requiresAuthorization: true
        )
        let appStore = AppUpdateTestFixtures.application(
            id: "app-store",
            availableVersion: "2.0",
            provider: .macAppStore,
            status: .updateAvailable
        )
        let plan = FrozenUpdatePlan(
            applications: [automatic, waitingForQuit, authorization, appStore],
            sessionID: UUID()
        )

        XCTAssertEqual(plan.plan.automaticApplicationIDs, ["automatic"])
        XCTAssertEqual(plan.plan.requiresQuitApplicationIDs, ["waiting-for-quit"])
        XCTAssertEqual(
            plan.automaticApplications.map(\.id),
            ["automatic", "waiting-for-quit"]
        )
        XCTAssertEqual(plan.plan.requiresAuthorizationApplicationIDs, ["authorization"])
        XCTAssertEqual(plan.plan.appStoreApplicationIDs, ["app-store"])
        XCTAssertTrue(plan.plan.websiteApplicationIDs.isEmpty)
        XCTAssertTrue(plan.plan.manualApplicationIDs.isEmpty)
        XCTAssertTrue(plan.plan.skippedApplicationIDs.isEmpty)
        XCTAssertEqual(
            plan.applications.map(\.id),
            ["automatic", "waiting-for-quit", "authorization", "app-store"]
        )
        XCTAssertEqual(plan.executionPlan.automaticApplicationIDs, ["automatic"])
        XCTAssertEqual(plan.executionPlan.requiresQuitApplicationIDs, ["waiting-for-quit"])
        XCTAssertTrue(plan.executionPlan.requiresAuthorizationApplicationIDs.isEmpty)
        XCTAssertEqual(plan.executionPlan.skippedApplicationIDs, ["authorization", "app-store"])
    }

    func testOneClickPlanStartsVerifiedRunningApplicationWaitingForQuit() async throws {
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
        var unverified = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "unverified",
            token: "unverified",
            path: "/Applications/Unverified.app",
            isRunning: true
        )
        unverified.signingTeamIdentifier = nil
        var duplicate = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "duplicate",
            token: "duplicate",
            path: "/Applications/Duplicate.app",
            isRunning: true
        )
        duplicate.isDuplicate = true
        var interactive = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "interactive",
            token: "interactive",
            path: "/Applications/Interactive.app",
            isRunning: true
        )
        interactive.requiresUserInteraction = true
        let appStore = AppUpdateTestFixtures.application(
            id: "app-store",
            provider: .macAppStore,
            status: .appStoreManaged
        )
        let manual = AppUpdateTestFixtures.application(
            id: "manual",
            availableVersion: "2.0",
            provider: .manual,
            status: .updateAvailable
        )

        let oneClick = AppUpdateService.oneClickPlan(
            for: [
                running, authorization, unverified, duplicate,
                interactive, appStore, manual,
            ]
        )
        XCTAssertEqual(oneClick.automaticApps.map(\.id), ["running"])

        let sessionID = UUID()
        let frozen = FrozenUpdatePlan(
            applications: oneClick.automaticApps,
            sessionID: sessionID
        )
        XCTAssertEqual(frozen.plan.requiresQuitApplicationIDs, ["running"])
        XCTAssertEqual(frozen.automaticApplications.map(\.id), ["running"])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMacTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ApplicationUpdateCoordinator(
            repository: ApplicationUpdateQueueRepository(
                fileURL: directory.appendingPathComponent("queue.json")
            ),
            executor: UnsupportedApplicationUpdateExecutor()
        )

        let snapshot = try await coordinator.start(
            plan: frozen.plan,
            applications: frozen.automaticApplications
        )

        XCTAssertEqual(snapshot.tasks.map(\.applicationID), ["running"])
        XCTAssertEqual(snapshot.tasks.map(\.state), [.waitingForQuit])
    }

    func testReportsDistinguishSuccessPartialFailureAndCancellation() {
        let app = AppUpdateTestFixtures.strictHomebrewApplication(id: "first")
        let second = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "second",
            token: "second",
            path: "/Applications/Second.app"
        )
        let allSuccess = report(applications: [app], states: [.completed])
        let partial = report(applications: [app, second], states: [.completed, .failed])
        let allFailed = report(applications: [app, second], states: [.failed, .failed])
        let cancelled = report(applications: [app], states: [.cancelled])

        XCTAssertEqual(allSuccess.outcome, .allSucceeded)
        XCTAssertEqual(partial.outcome, .partialSuccess)
        XCTAssertEqual(allFailed.outcome, .allFailed)
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertEqual(partial.items[1].errorDescription, "provider failed")
        XCTAssertEqual(partial.items[1].attemptCount, 2)
        XCTAssertEqual(partial.retryableApplicationIDs, ["second"])
    }

    func testSessionSnapshotUsesOnlyRealProviderFractions() throws {
        let first = AppUpdateTestFixtures.strictHomebrewApplication(id: "first")
        let second = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "second",
            token: "second",
            path: "/Applications/Second.app"
        )
        var snapshot = queue(applications: [first, second], states: [.completed, .downloading])
        snapshot.tasks[1].progressFraction = 0.5

        let session = AppUpdateSessionSnapshot(
            queue: snapshot,
            applications: [first, second]
        )

        XCTAssertEqual(try XCTUnwrap(session.processedFraction), 0.75, accuracy: 0.000_1)
        snapshot.tasks[1].progressFraction = nil
        XCTAssertEqual(
            try XCTUnwrap(
                AppUpdateSessionSnapshot(queue: snapshot, applications: [first, second])
                    .processedFraction
            ),
            0.5,
            accuracy: 0.000_1
        )

        let cancelling = AppUpdateSessionSnapshot(
            queue: snapshot,
            applications: [first, second],
            isCancellationRequested: true
        )
        XCTAssertTrue(cancelling.isCancellationRequested)
    }

    func testPresentationMachineRejectsStalePayloadAndInvalidTransitions() {
        let firstSession = UUID()
        let secondSession = UUID()
        var machine = AppUpdatePresentationMachine(sessionID: firstSession)
        let staleToken = machine.activeToken
        let token = machine.beginSession(sessionID: secondSession)
        let progress = AppScanProgressSnapshot(
            sessionID: secondSession,
            generatedAt: Date(),
            stage: .discoveringApplications,
            completedUnitCount: 0,
            totalUnitCount: nil,
            currentApplicationID: nil,
            currentApplicationName: nil
        )

        XCTAssertEqual(
            machine.transition(to: .scanning(progress), token: staleToken),
            .rejected(.staleToken(expected: token, received: staleToken))
        )
        XCTAssertEqual(machine.transition(to: .scanning(progress), token: token), .applied)

        let wrongSummary = AppScanSummary(
            sessionID: firstSession,
            applications: []
        )
        XCTAssertEqual(
            machine.transition(to: .scanSummary(wrongSummary), token: token),
            .rejected(
                .payloadSessionMismatch(expected: secondSession, received: firstSession)
            )
        )

        let report = AppUpdateReport(sessionID: secondSession, sessionError: "failed")
        XCTAssertEqual(
            machine.transition(to: .completed(report), token: token),
            .rejected(.invalidTransition(from: .scanning, to: .completed))
        )
        XCTAssertEqual(machine.state.phase, .scanning)
    }

    func testTerminalStatesCanReturnToScanSummary() {
        XCTAssertTrue(AppUpdatePresentationMachine.canTransition(from: .completed, to: .scanSummary))
        XCTAssertTrue(AppUpdatePresentationMachine.canTransition(from: .cancelled, to: .scanSummary))
        XCTAssertTrue(AppUpdatePresentationMachine.canTransition(from: .failed, to: .scanSummary))
        XCTAssertTrue(AppUpdatePresentationMachine.canTransition(from: .completed, to: .updating))
        XCTAssertTrue(AppUpdatePresentationMachine.canTransition(from: .cancelled, to: .updating))
        XCTAssertTrue(AppUpdatePresentationMachine.canTransition(from: .failed, to: .updating))
    }

    private func confirmedOfficialSource(
        for application: InstalledApplication
    ) -> OfficialUpdateSource {
        OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialWebsite,
            developerName: "Example",
            homepageURL: URL(string: "https://example.com"),
            updatePageURL: URL(string: "https://example.com/update"),
            releaseFeedURL: nil,
            directDownloadURL: nil,
            allowedHosts: ["example.com"],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .userConfirmation,
            trustLevel: .userConfirmed,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: .manualWebsite,
            expectedPackageExtensions: [],
            officialGitHubRepository: nil
        )
    }

    private func report(
        applications: [InstalledApplication],
        states: [ApplicationUpdateTaskState]
    ) -> AppUpdateReport {
        let queue = queue(applications: applications, states: states)
        return AppUpdateReport(
            snapshot: AppUpdateSessionSnapshot(queue: queue, applications: applications)
        )
    }

    private func queue(
        applications: [InstalledApplication],
        states: [ApplicationUpdateTaskState]
    ) -> ApplicationUpdateQueueSnapshot {
        let sessionID = UUID()
        let plan = ApplicationUpdatePlan(
            id: sessionID,
            automaticApplicationIDs: applications.map(\.id),
            requiresQuitApplicationIDs: [],
            requiresAuthorizationApplicationIDs: [],
            appStoreApplicationIDs: [],
            websiteApplicationIDs: [],
            manualApplicationIDs: [],
            skippedApplicationIDs: []
        )
        let tasks = zip(applications, states).map { application, state in
            var task = ApplicationUpdateTask(
                sessionID: sessionID,
                application: application,
                state: state
            )
            if state == .failed {
                task.errorDescription = "provider failed"
                task.attemptCount = 2
            }
            return task
        }
        return ApplicationUpdateQueueSnapshot(
            schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion,
            plan: plan,
            tasks: tasks,
            isPaused: false,
            updatedAt: Date()
        )
    }
}
