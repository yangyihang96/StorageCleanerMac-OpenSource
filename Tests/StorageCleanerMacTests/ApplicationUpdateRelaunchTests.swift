import Foundation
import XCTest
@testable import StorageCleanerMac

final class ApplicationUpdateRelaunchTests: XCTestCase {
    @MainActor
    func testConfirmedAcceptedQuitRelaunchesCompletedApplicationAtMostOnce() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }

        context.store.previewOneClickAppUpdates()
        context.store.confirmOneClickAppUpdates()
        try await waitUntil {
            context.quit.count == 1
                && context.store.appUpdateQueueSnapshot?.tasks.first?.state == .waitingForQuit
        }
        context.store.applicationDidTerminateForUpdates(
            bundleIdentifier: context.application.bundleIdentifier,
            bundleURL: context.application.bundleURL
        )
        try await waitUntil {
            context.launch.urls.count == 1 && !context.store.isRunningOneClickUpdate
        }

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(context.launch.urls, [context.application.bundleURL.standardizedFileURL])
    }

    @MainActor
    func testDisabledOptionAndRejectedQuitNeverRelaunch() async throws {
        let disabled = try makeContext()
        defer { try? FileManager.default.removeItem(at: disabled.root) }
        disabled.store.previewOneClickAppUpdates()
        disabled.store.confirmOneClickAppUpdates(reopensUpdatedApplications: false)
        try await waitUntil {
            disabled.quit.count == 1
                && disabled.store.appUpdateQueueSnapshot?.tasks.first?.state == .waitingForQuit
        }
        disabled.store.applicationDidTerminateForUpdates(
            bundleIdentifier: disabled.application.bundleIdentifier,
            bundleURL: disabled.application.bundleURL
        )
        try await waitUntil { !disabled.store.isRunningOneClickUpdate }
        XCTAssertTrue(disabled.launch.urls.isEmpty)

        let rejected = try makeContext(quitAccepted: false)
        defer { try? FileManager.default.removeItem(at: rejected.root) }
        rejected.store.previewOneClickAppUpdates()
        rejected.store.confirmOneClickAppUpdates()
        try await waitUntil {
            rejected.quit.count == 1
                && rejected.store.appUpdateQueueSnapshot?.tasks.first?.state == .waitingForQuit
        }
        rejected.store.cancelOneClickAppUpdates()
        try await waitUntil { !rejected.store.isRunningOneClickUpdate }
        XCTAssertTrue(rejected.launch.urls.isEmpty)
    }

    @MainActor
    func testRestoredCompletedSessionHasNoRelaunchAuthority() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let sessionID = UUID()
        let plan = FrozenUpdatePlan(
            applications: [context.application],
            sessionID: sessionID
        ).executionPlan
        let snapshot = ApplicationUpdateQueueSnapshot(
            schemaVersion: ApplicationUpdateQueueRepository.currentSchemaVersion,
            plan: plan,
            tasks: [ApplicationUpdateTask(
                sessionID: sessionID,
                application: context.application,
                state: .completed
            )],
            isPaused: false,
            updatedAt: Date()
        )

        XCTAssertTrue(context.store.applyApplicationUpdateCoordinatorEvent(
            .restored(snapshot),
            expectedSessionID: sessionID
        ))
        XCTAssertTrue(context.store.applyApplicationUpdateCoordinatorEvent(
            .drained(snapshot),
            expectedSessionID: sessionID
        ))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(context.launch.urls.isEmpty)
    }

    @MainActor
    func testRelauncherRejectsChangedSigningIdentityAndSkipsAlreadyRunningApp() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let application = application(at: root, id: "identity")
        let target = try XCTUnwrap(ApplicationUpdateRelauncher.Target(application: application))
        let launch = RelaunchLaunchRecorder()
        let changedIdentity = ApplicationIdentity(
            bundleIdentifier: application.bundleIdentifier,
            signingTeamIdentifier: "OTHERTEAM",
            codeSigningIdentifier: application.codeSigningIdentifier
        )
        let changed = ApplicationUpdateRelauncher(
            runningApplications: { [] },
            installedIdentity: { _ in changedIdentity },
            openApplication: launch.open
        )

        do {
            _ = try await changed.relaunch(target)
            XCTFail("A changed signing identity must fail closed")
        } catch is ApplicationUpdateRelauncher.RelaunchError {
            XCTAssertTrue(launch.urls.isEmpty)
        }

        let alreadyRunning = ApplicationUpdateRelauncher(
            runningApplications: {
                [ApplicationUpdateRelauncher.RunningApplication(
                    bundleIdentifier: application.bundleIdentifier,
                    bundleURL: application.bundleURL
                )]
            },
            installedIdentity: { _ in application.identity },
            openApplication: launch.open
        )
        let outcome = try await alreadyRunning.relaunch(target)
        XCTAssertEqual(outcome, .alreadyRunning)
        XCTAssertTrue(launch.urls.isEmpty)
    }

    @MainActor
    func testRelaunchFailureIsReportedWithoutChangingVerifiedUpdateSuccess() async throws {
        let context = try makeContext(openError: RelaunchTestError.openFailed)
        defer { try? FileManager.default.removeItem(at: context.root) }
        context.store.previewOneClickAppUpdates()
        context.store.confirmOneClickAppUpdates()
        try await waitUntil {
            context.quit.count == 1
                && context.store.appUpdateQueueSnapshot?.tasks.first?.state == .waitingForQuit
        }
        context.store.applicationDidTerminateForUpdates(
            bundleIdentifier: context.application.bundleIdentifier,
            bundleURL: context.application.bundleURL
        )
        try await waitUntil {
            !context.store.appUpdateScanWarnings.isEmpty
                && !context.store.isRunningOneClickUpdate
        }

        XCTAssertEqual(context.store.oneClickUpdateResult?.automatic.status, .succeeded)
        XCTAssertEqual(context.launch.urls.count, 1)
    }

    @MainActor
    private func makeContext(
        quitAccepted: Bool = true,
        openError: Error? = nil
    ) throws -> RelaunchTestContext {
        let root = try temporaryDirectory()
        let application = application(at: root, id: UUID().uuidString)
        let quit = RelaunchQuitRecorder(accepted: quitAccepted)
        let launch = RelaunchLaunchRecorder(error: openError)
        let requester = ApplicationUpdateGracefulQuitRequester {
            [ApplicationUpdateGracefulQuitRequester.RunningApplication(
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL,
                requestTermination: quit.request
            )]
        }
        let relauncher = ApplicationUpdateRelauncher(
            runningApplications: { [] },
            installedIdentity: { _ in application.identity },
            openApplication: launch.open
        )
        let coordinator = ApplicationUpdateCoordinator(
            repository: ApplicationUpdateQueueRepository(
                fileURL: root.appendingPathComponent("queue.json")
            ),
            executor: RelaunchSuccessfulExecutor()
        )
        let store = ScanStore(
            applicationInventoryScanner: RelaunchInventoryScanner(
                applications: [application]
            ),
            applicationUpdateCoordinator: coordinator,
            applicationUpdateGracefulQuitRequester: requester,
            applicationUpdateRelauncher: relauncher
        )
        store.appUpdates = [application]
        return RelaunchTestContext(
            root: root,
            application: application,
            store: store,
            quit: quit,
            launch: launch
        )
    }

    private func application(at root: URL, id: String) -> InstalledApplication {
        AppUpdateTestFixtures.strictHomebrewApplication(
            id: id,
            token: "relaunch",
            path: root.appendingPathComponent("Relaunch.app", isDirectory: true).path,
            isRunning: true
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationUpdateRelaunchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(4),
        _ predicate: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RelaunchTestError.timedOut
    }
}

@MainActor
private struct RelaunchTestContext {
    let root: URL
    let application: InstalledApplication
    let store: ScanStore
    let quit: RelaunchQuitRecorder
    let launch: RelaunchLaunchRecorder
}

@MainActor
private final class RelaunchQuitRecorder {
    let accepted: Bool
    private(set) var count = 0

    init(accepted: Bool) {
        self.accepted = accepted
    }

    func request() -> Bool {
        count += 1
        return accepted
    }
}

@MainActor
private final class RelaunchLaunchRecorder {
    let error: Error?
    private(set) var urls: [URL] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func open(_ url: URL) async throws {
        urls.append(url.standardizedFileURL)
        if let error { throw error }
    }
}

private struct RelaunchInventoryScanner: ApplicationInventoryScanning {
    let applications: [InstalledApplication]

    func scan(
        configuration: ApplicationScanConfiguration,
        onProgress: @escaping @Sendable (ApplicationScanProgress) async -> Void,
        onApplications: @escaping @Sendable ([InstalledApplication]) async -> Void
    ) async throws -> [InstalledApplication] {
        await onApplications(applications)
        await onProgress(ApplicationScanProgress(
            stage: .completed,
            scannedCount: applications.count,
            discoveredCount: applications.count
        ))
        return applications
    }
}

private struct RelaunchSuccessfulExecutor: ApplicationUpdateExecuting {
    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        ApplicationUpdateInstallResult(
            applicationID: application.id,
            state: .completed,
            observedVersion: application.availableVersion,
            detail: "fixture verified"
        )
    }

    func cancel(applicationID: String) async {}

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult {
        ApplicationUpdateInstallResult(
            applicationID: task.applicationID,
            state: .completed,
            observedVersion: application?.availableVersion,
            detail: "fixture reconciled"
        )
    }
}

private enum RelaunchTestError: Error {
    case openFailed
    case timedOut
}
