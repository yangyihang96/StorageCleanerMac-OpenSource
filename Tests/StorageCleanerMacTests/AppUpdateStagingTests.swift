import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateStagingTests: XCTestCase {
    private var fixtureRoots = [URL]()

    override func tearDown() {
        for root in fixtureRoots {
            try? FileManager.default.removeItem(at: root)
        }
        fixtureRoots.removeAll()
        super.tearDown()
    }

    func testOfficialWebsiteStagingOverlapsTwoDownloadsButStagesEachItemOnce() async throws {
        let recorder = StagingRecorder()
        let provider = FixtureStagingProvider(recorder: recorder)
        let executor = makeExecutor(provider: provider)
        let applications = makeApplications(ids: ["one", "two"])
        let tasks = makeTasks(applications: applications)

        let report = await executor.stageDownloads(
            applications: applications,
            tasks: tasks,
            progress: { _ in }
        )

        XCTAssertEqual(report.stagedApplicationIDs, ["one", "two"])
        XCTAssertTrue(report.failedApplicationDetails.isEmpty)
        let maximumConcurrentStages = await recorder.maximumConcurrentStages()
        let stageCounts = await recorder.stageCounts()
        let prepareCounts = await recorder.prepareCounts()
        XCTAssertEqual(maximumConcurrentStages, 2)
        XCTAssertEqual(stageCounts, ["one": 1, "two": 1])
        XCTAssertEqual(prepareCounts, ["one": 1, "two": 1])

        await executor.discardStagedDownloads()
        let stagedAfterDiscard = await recorder.stagedIDs()
        XCTAssertEqual(stagedAfterDiscard, Set<String>())
    }

    func testOneStageFailureDoesNotBlockTheOtherOfficialDownload() async throws {
        let recorder = StagingRecorder()
        let provider = FixtureStagingProvider(
            recorder: recorder,
            failingApplicationIDs: ["bad"]
        )
        let executor = makeExecutor(provider: provider)
        let applications = makeApplications(ids: ["bad", "good"])
        let tasks = makeTasks(applications: applications)

        let report = await executor.stageDownloads(
            applications: applications,
            tasks: tasks,
            progress: { _ in }
        )

        XCTAssertEqual(report.stagedApplicationIDs, ["good"])
        XCTAssertEqual(Set(report.failedApplicationDetails.keys), ["bad"])
        let stageCounts = await recorder.stageCounts()
        let stagedIDs = await recorder.stagedIDs()
        XCTAssertEqual(stageCounts, ["bad": 1, "good": 1])
        XCTAssertEqual(stagedIDs, ["good"])

        await executor.discardStagedDownloads()
        let stagedAfterDiscard = await recorder.stagedIDs()
        XCTAssertEqual(stagedAfterDiscard, Set<String>())
    }

    func testStagingPreflightRejectsChangedVersionAndIdentityButStagesSibling() async throws {
        let recorder = StagingRecorder()
        let provider = FixtureStagingProvider(recorder: recorder)
        let executor = makeExecutor(provider: provider)
        let applications = makeApplications(ids: ["changed-version", "changed-identity", "good"])
        try rewriteFixtureBundle(
            at: applications[0].bundleURL,
            bundleIdentifier: applications[0].bundleIdentifier,
            version: "1.1",
            build: "110"
        )
        try rewriteFixtureBundle(
            at: applications[1].bundleURL,
            bundleIdentifier: "com.example.changed-identity",
            version: "1.0",
            build: "100"
        )

        let report = await executor.stageDownloads(
            applications: applications,
            tasks: makeTasks(applications: applications),
            progress: { _ in }
        )

        XCTAssertEqual(report.stagedApplicationIDs, ["good"])
        XCTAssertEqual(Set(report.failedApplicationDetails.keys), ["changed-version", "changed-identity"])
        let prepareCounts = await recorder.prepareCounts()
        let stageCounts = await recorder.stageCounts()
        XCTAssertEqual(prepareCounts, ["good": 1])
        XCTAssertEqual(stageCounts, ["good": 1])
    }

    func testStagingPreflightRejectsInsufficientSpaceWithoutBlockingSibling() async throws {
        let recorder = StagingRecorder()
        let provider = FixtureStagingProvider(recorder: recorder)
        let executor = makeExecutor(
            provider: provider,
            diskSpacePolicy: ApplicationUpdateDiskSpacePolicy(
                minimumUnknownDownloadHeadroomBytes: 1_024,
                knownDownloadMultiplier: 3
            ),
            availableDiskCapacity: { url in
                url.path.contains("changed-space") ? 512 : Int64.max
            }
        )
        let applications = makeApplications(ids: ["changed-space", "good-space"])

        let report = await executor.stageDownloads(
            applications: applications,
            tasks: makeTasks(applications: applications),
            progress: { _ in }
        )

        XCTAssertEqual(report.stagedApplicationIDs, ["good-space"])
        XCTAssertEqual(Set(report.failedApplicationDetails.keys), ["changed-space"])
        let prepareCounts = await recorder.prepareCounts()
        let stageCounts = await recorder.stageCounts()
        XCTAssertEqual(prepareCounts, ["good-space": 1])
        XCTAssertEqual(stageCounts, ["good-space": 1])
    }

    func testInstallTimePreflightFailureDiscardsPreviouslyStagedArtifact() async throws {
        let recorder = StagingRecorder()
        let provider = FixtureStagingProvider(recorder: recorder)
        let executor = makeExecutor(provider: provider)
        let application = makeApplications(ids: ["changed-after-stage"])[0]
        let task = makeTasks(applications: [application])[0]

        let report = await executor.stageDownloads(
            applications: [application],
            tasks: [task],
            progress: { _ in }
        )
        XCTAssertEqual(report.stagedApplicationIDs, [application.id])
        let stagedBeforePreflight = await recorder.stagedIDs()
        XCTAssertEqual(stagedBeforePreflight, [application.id])

        try rewriteFixtureBundle(
            at: application.bundleURL,
            bundleIdentifier: application.bundleIdentifier,
            version: "1.1",
            build: "110"
        )
        do {
            _ = try await executor.execute(
                application: application,
                task: task,
                progress: { _ in }
            )
            XCTFail("Install-time preflight must reject the changed on-disk version")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }

        let stagedAfterPreflight = await recorder.stagedIDs()
        let discardedIDs = await recorder.discardedIDs()
        XCTAssertEqual(stagedAfterPreflight, Set<String>())
        XCTAssertEqual(discardedIDs, [application.id])
    }

    func testRestagingSameApplicationDiscardsPriorArtifactBeforeReplacement() async throws {
        let recorder = StagingRecorder()
        let provider = FixtureStagingProvider(recorder: recorder)
        let executor = makeExecutor(provider: provider)
        let application = makeApplications(ids: ["restaged"])[0]
        let task = makeTasks(applications: [application])[0]

        for _ in 0..<2 {
            let report = await executor.stageDownloads(
                applications: [application],
                tasks: [task],
                progress: { _ in }
            )
            XCTAssertEqual(report.stagedApplicationIDs, [application.id])
        }

        let prepareCounts = await recorder.prepareCounts()
        let stageCounts = await recorder.stageCounts()
        let stagedIDs = await recorder.stagedIDs()
        let discardedIDs = await recorder.discardedIDs()
        XCTAssertEqual(prepareCounts, [application.id: 2])
        XCTAssertEqual(stageCounts, [application.id: 2])
        XCTAssertEqual(stagedIDs, [application.id])
        XCTAssertEqual(discardedIDs, [application.id])

        await executor.discardStagedDownloads()
    }

    func testStagingPhaseExcludesHomebrewAndAppStoreTasks() async throws {
        let recorder = StagingRecorder()
        let provider = FixtureStagingProvider(recorder: recorder)
        let executor = makeExecutor(provider: provider)
        let official = makeApplications(ids: ["official"])[0]
        let homebrew = AppUpdateTestFixtures.strictHomebrewApplication(
            id: "homebrew",
            token: "homebrew"
        )
        let appStore = AppUpdateTestFixtures.application(
            id: "app-store",
            name: "App Store Fixture",
            bundleIdentifier: "com.example.app-store",
            path: "/Applications/App-Store-Fixture.app",
            availableVersion: "2.0",
            provider: .macAppStore,
            status: .automaticallyUpdatable,
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )
        let applications = [official, homebrew, appStore]
        let report = await executor.stageDownloads(
            applications: applications,
            tasks: makeTasks(applications: applications),
            progress: { _ in }
        )

        XCTAssertEqual(report.stagedApplicationIDs, ["official"])
        XCTAssertTrue(report.failedApplicationDetails.isEmpty)
        let stageCounts = await recorder.stageCounts()
        XCTAssertEqual(stageCounts, ["official": 1])
        await executor.discardStagedDownloads()
    }

    func testCancellingStagingDiscardsPartialArtifactsAndDoesNotLeaveActiveStage() async throws {
        let recorder = StagingRecorder()
        let provider = FixtureStagingProvider(
            recorder: recorder,
            stageDelay: .seconds(10)
        )
        let executor = makeExecutor(provider: provider)
        let applications = makeApplications(ids: ["cancelled"])
        let tasks = makeTasks(applications: applications)

        let stagingTask = Task {
            await executor.stageDownloads(
                applications: applications,
                tasks: tasks,
                progress: { _ in }
            )
        }
        try await waitForStagingActivity(recorder)
        stagingTask.cancel()
        let report = await stagingTask.value

        XCTAssertTrue(report.stagedApplicationIDs.isEmpty)
        XCTAssertTrue(report.failedApplicationDetails.isEmpty)
        let stagedIDs = await recorder.stagedIDs()
        let discardedIDs = await recorder.discardedIDs()
        let activeStages = await recorder.activeStages()
        XCTAssertEqual(stagedIDs, Set<String>())
        XCTAssertEqual(discardedIDs, ["cancelled"])
        XCTAssertEqual(activeStages, 0)
    }

    private func makeExecutor(provider: FixtureStagingProvider) -> ProviderBackedApplicationUpdateExecutor {
        makeExecutor(
            provider: provider,
            diskSpacePolicy: .standard,
            availableDiskCapacity: { _ in Int64.max }
        )
    }

    private func makeExecutor(
        provider: FixtureStagingProvider,
        diskSpacePolicy: ApplicationUpdateDiskSpacePolicy,
        availableDiskCapacity: @escaping @Sendable (URL) throws -> Int64?
    ) -> ProviderBackedApplicationUpdateExecutor {
        ProviderBackedApplicationUpdateExecutor(
            providerRegistry: ApplicationUpdateProviderRegistry(providers: [provider]),
            metadataReader: ApplicationMetadataReader(
                signatureInspector: FixtureApplicationSignatureInspector()
            ),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            runningStateProvider: {
                ApplicationRunningStateSnapshot(
                    bundleIdentifiers: [],
                    normalizedBundlePaths: []
                )
            },
            diskSpacePolicy: diskSpacePolicy,
            availableDiskCapacity: availableDiskCapacity
        )
    }

    private func makeApplications(ids: [String]) -> [InstalledApplication] {
        ids.map { id in
            let bundleURL = makeFixtureBundle(
                id: id,
                bundleIdentifier: "com.example.\(id)",
                version: "1.0",
                build: "100"
            )
            var application = AppUpdateTestFixtures.application(
                id: id,
                name: "Fixture \(id)",
                bundleIdentifier: "com.example.\(id)",
                path: bundleURL.path,
                availableVersion: "2.0",
                provider: .officialWebsite,
                status: .automaticallyUpdatable,
                sourceEvidence: ["fixture-official-website"],
                canAutomaticallyUpdate: true,
                requiresUserInteraction: false
            )
            application.officialSource = fixtureOfficialSource(for: application)
            return application
        }
    }

    private func makeTasks(applications: [InstalledApplication]) -> [ApplicationUpdateTask] {
        let sessionID = UUID()
        return applications.map {
            ApplicationUpdateTask(sessionID: sessionID, application: $0)
        }
    }

    private func waitForStagingActivity(_ recorder: StagingRecorder) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if await recorder.activeStages() > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The fixture staging provider did not start")
    }

    private func makeFixtureBundle(
        id: String,
        bundleIdentifier: String,
        version: String,
        build: String
    ) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "StorageCleanerMac-AppUpdateStaging-\(id)-\(UUID().uuidString)",
                isDirectory: true
            )
        let appURL = root.appendingPathComponent("Fixture-\(id).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let executableURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Fixture", isDirectory: false)
        try! FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Fixture",
            "CFBundleDisplayName": "Fixture",
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        let plistData = try! PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try! plistData.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            options: .atomic
        )
        try! Data("fixture".utf8).write(to: executableURL, options: .atomic)
        fixtureRoots.append(root)
        return appURL
    }

    private func rewriteFixtureBundle(
        at appURL: URL,
        bundleIdentifier: String,
        version: String,
        build: String
    ) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Fixture",
            "CFBundleDisplayName": "Fixture",
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(
            to: appURL.appendingPathComponent("Contents/Info.plist"),
            options: .atomic
        )
    }

    private func fixtureOfficialSource(for application: InstalledApplication) -> OfficialUpdateSource {
        OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .officialWebsite,
            developerName: "StorageCleanerMac Fixture",
            homepageURL: URL(string: "https://updates.example.com"),
            updatePageURL: URL(string: "https://updates.example.com/fixture"),
            releaseFeedURL: nil,
            directDownloadURL: URL(string: "https://downloads.example.com/fixture.dmg"),
            allowedHosts: ["updates.example.com", "downloads.example.com"],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .signedRegistry,
            trustLevel: .registryVerified,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: .automatic,
            expectedPackageExtensions: [OfficialPackageType.diskImage.rawValue],
            officialGitHubRepository: nil
        )
    }
}

private actor StagingRecorder {
    private var active = 0
    private var maximumActive = 0
    private var prepareCallCounts: [String: Int] = [:]
    private var stageCallCounts: [String: Int] = [:]
    private var staged: Set<String> = []
    private var discarded: Set<String> = []

    func beginPrepare(_ id: String) {
        prepareCallCounts[id, default: 0] += 1
    }

    func beginStage(_ id: String) {
        stageCallCounts[id, default: 0] += 1
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func endStage(_ id: String, didStage: Bool) {
        active = max(0, active - 1)
        if didStage { staged.insert(id) }
    }

    func discard(_ id: String) {
        staged.remove(id)
        discarded.insert(id)
    }

    func maximumConcurrentStages() -> Int { maximumActive }
    func activeStages() -> Int { active }
    func prepareCounts() -> [String: Int] { prepareCallCounts }
    func stageCounts() -> [String: Int] { stageCallCounts }
    func stagedIDs() -> Set<String> { staged }
    func discardedIDs() -> Set<String> { discarded }
}

private enum FixtureStagingError: LocalizedError {
    case intentionalFailure(String)

    var errorDescription: String? {
        switch self {
        case let .intentionalFailure(id): "intentional staging failure for \(id)"
        }
    }
}

private final class FixtureStagingProvider: ApplicationUpdateStagingProvider, @unchecked Sendable {
    let identifier = ApplicationUpdateProviderIdentifier.officialWebsite
    private let recorder: StagingRecorder
    private let failingApplicationIDs: Set<String>
    private let stageDelay: Duration
    private let lock = NSLock()
    private var prepared: [String: PreparedApplicationUpdate] = [:]
    private var staged: [String: PreparedApplicationUpdate] = [:]

    init(
        recorder: StagingRecorder,
        failingApplicationIDs: Set<String> = [],
        stageDelay: Duration = .milliseconds(80)
    ) {
        self.recorder = recorder
        self.failingApplicationIDs = failingApplicationIDs
        self.stageDelay = stageDelay
    }

    func canHandle(_ application: InstalledApplication) async -> Bool {
        application.updateProvider == .officialWebsite
    }

    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        ApplicationUpdateSourceInfo(
            providerIdentifier: identifier,
            evidence: ["fixture"],
            requiresUserInteraction: false,
            canAutomaticallyUpdate: true
        )
    }

    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult {
        ApplicationUpdateCheckResult(
            status: .automaticallyUpdatable,
            availableVersion: application.availableVersion,
            releaseDate: nil,
            releaseNotes: nil,
            downloadSize: 1,
            warning: nil
        )
    }

    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate {
        await recorder.beginPrepare(application.id)
        let preparedUpdate = PreparedApplicationUpdate(
            applicationID: application.id,
            providerIdentifier: identifier,
            originalIdentity: application.identity,
            originalVersion: application.installedVersion,
            targetVersion: application.availableVersion,
            providerPayload: ["fixture": "true"]
        )
        lock.withLock { prepared[application.id] = preparedUpdate }
        return preparedUpdate
    }

    func stage(
        _ preparedUpdate: PreparedApplicationUpdate,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws {
        await recorder.beginStage(preparedUpdate.applicationID)
        progress(
            ApplicationUpdateProgressEvent(
                applicationID: preparedUpdate.applicationID,
                state: .downloading,
                fraction: 0.1,
                detail: "fixture stage"
            )
        )
        do {
            try await Task.sleep(for: stageDelay)
            try Task.checkCancellation()
            if failingApplicationIDs.contains(preparedUpdate.applicationID) {
                throw FixtureStagingError.intentionalFailure(preparedUpdate.applicationID)
            }
            lock.withLock { staged[preparedUpdate.applicationID] = preparedUpdate }
            await recorder.endStage(preparedUpdate.applicationID, didStage: true)
        } catch {
            await recorder.endStage(preparedUpdate.applicationID, didStage: false)
            throw error
        }
    }

    func stagedPreparedUpdate(for applicationID: String) -> PreparedApplicationUpdate? {
        lock.withLock { prepared[applicationID] }
    }

    func discardStagedUpdate(for applicationID: String) async {
        lock.withLock {
            staged.removeValue(forKey: applicationID)
            prepared.removeValue(forKey: applicationID)
        }
        await recorder.discard(applicationID)
    }

    func install(
        _ preparedUpdate: PreparedApplicationUpdate,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        ApplicationUpdateInstallResult(
            applicationID: preparedUpdate.applicationID,
            state: .completed,
            observedVersion: preparedUpdate.targetVersion,
            detail: "fixture installed"
        )
    }
}

private struct FixtureApplicationSignatureInspector: ApplicationCodeSignatureInspecting {
    func inspectSignature(at applicationURL: URL) async -> ApplicationCodeSignatureMetadata {
        let identityChanged = applicationURL.path.contains("changed-identity")
        return ApplicationCodeSignatureMetadata(
            signingTeamIdentifier: identityChanged ? "OTHERTEAM" : "TEAM123",
            codeSigningIdentifier: Bundle(url: applicationURL)?.bundleIdentifier,
            isValid: true
        )
    }
}
