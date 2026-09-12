import XCTest
@testable import StorageCleanerMac

final class DebugAppUpdatePresentationReleaseIsolationTests: XCTestCase {
    func testFixtureAndCommandEntryDisappearFromReleaseProjection() throws {
        let fixtureSource = try source(
            "Sources/StorageCleanerMac/Debug/DebugAppUpdatePresentationFixture.swift"
        )
        let storeSource = try source("Sources/StorageCleanerMac/Stores/ScanStore.swift")
        let contentSource = try source("Sources/StorageCleanerMac/Views/ContentView.swift")

        XCTAssertTrue(fixtureSource.contains("#if DEBUG"))
        XCTAssertTrue(storeSource.contains(
            "@Published private(set) var isDebugAppUpdatePresentationFixtureActive"
        ))
        XCTAssertTrue(contentSource.contains("#if DEBUG\n    private var debugAppUpdatePresentation"))

        for projectedSource in [fixtureSource, storeSource, contentSource].map(releaseProjection) {
            XCTAssertFalse(projectedSource.contains("--debug-app-updates"))
            XCTAssertFalse(projectedSource.contains("DebugAppUpdatePresentationFixture"))
            XCTAssertFalse(projectedSource.contains("isDebugAppUpdatePresentationFixtureActive"))
        }
    }

    private func releaseProjection(_ source: String) -> String {
        var debugDepth = 0
        return source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "#if DEBUG" {
                debugDepth = 1
                return nil
            }
            if debugDepth > 0 {
                if trimmed.hasPrefix("#if ") { debugDepth += 1 }
                if trimmed == "#endif" { debugDepth -= 1 }
                return nil
            }
            return String(line)
        }.joined(separator: "\n")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

#if DEBUG
@MainActor
final class DebugAppUpdatePresentationFixtureTests: XCTestCase {
    func testLaunchArgumentRecognizesOnlyExplicitScenarios() {
        XCTAssertEqual(
            DebugAppUpdatePresentationFixture.scenario(arguments: [
                DebugAppUpdatePresentationFixture.launchArgument,
                "managing",
            ]),
            .managing
        )
        XCTAssertNil(DebugAppUpdatePresentationFixture.scenario(arguments: [
            DebugAppUpdatePresentationFixture.launchArgument,
            "unknown-scenario",
        ]))
        XCTAssertNil(DebugAppUpdatePresentationFixture.scenario(arguments: [
            "--open-filter",
            "updater",
        ]))
    }

    func testScenariosCoverEveryVisualAcceptanceBoundary() {
        let expected: [DebugAppUpdatePresentationFixture.Scenario: AppUpdatePresentationPhase] = [
            .idle: .idle,
            .scanning: .scanning,
            .summary: .scanSummary,
            .managing: .managing,
            .updating: .updating,
            .partial: .completed,
            .failed: .failed,
        ]

        XCTAssertEqual(Set(expected.keys), Set(DebugAppUpdatePresentationFixture.Scenario.allCases))
        for (scenario, phase) in expected {
            XCTAssertEqual(
                DebugAppUpdatePresentationFixture.presentationState(for: scenario).phase,
                phase
            )
        }
    }

    func testSyntheticCatalogHasTwoStrictlyEligibleAutomaticApps() {
        let apps = DebugAppUpdatePresentationFixture.applications
        let eligible = apps.filter(\.canJoinAutomaticUpdatePlan)

        XCTAssertEqual(eligible.map(\.id), ["aurora-studio", "lumen-capture"])
        XCTAssertTrue(apps.allSatisfy { $0.path.hasPrefix("/DebugAppUpdates/") })
        XCTAssertTrue(apps.compactMap(\.releaseNotes).allSatisfy { $0.contains("界面演示") })
    }

    func testPartialAndFailedReportsUseRealTerminalTaskSemantics() {
        guard case let .completed(partial) = DebugAppUpdatePresentationFixture
            .presentationState(for: .partial),
              case let .failed(failed) = DebugAppUpdatePresentationFixture
                .presentationState(for: .failed) else {
            return XCTFail("Expected report states")
        }

        XCTAssertEqual(partial.outcome, .partialSuccess)
        XCTAssertEqual(partial.succeededCount, 1)
        XCTAssertEqual(partial.failedCount, 1)
        XCTAssertEqual(failed.outcome, .allFailed)
        XCTAssertEqual(failed.failedCount, 2)
    }

    func testInstalledFixtureClearsBusyStateAndBlocksLiveEntryPoints() {
        let store = ScanStore()
        store.installDebugAppUpdatePresentationFixture(.summary)
        let installedState = store.appUpdatePresentationState

        XCTAssertTrue(store.isDebugAppUpdatePresentationFixtureActive)
        XCTAssertFalse(store.isLoadingAppUpdates)
        XCTAssertFalse(store.isRunningOneClickUpdate)
        XCTAssertFalse(store.canRefreshAppUpdates)
        XCTAssertFalse(store.canRequestOneClickAppUpdates)
        XCTAssertFalse(store.canModifyAppUpdateList)
        XCTAssertNil(store.appUpdateQueueSnapshot)
        XCTAssertEqual(store.appUpdatesLastScannedAt, DebugAppUpdatePresentationFixture.referenceDate)

        store.prepareApplicationUpdatesOnLaunch()
        store.refreshAppUpdates()
        store.requestOneClickAppUpdates()
        store.requestSelectedAppUpdates(applicationIDs: ["aurora-studio"])
        store.requestAppUpdate(DebugAppUpdatePresentationFixture.applications[0])

        XCTAssertEqual(store.appUpdatePresentationState, installedState)
        XCTAssertFalse(store.isLoadingAppUpdates)
        XCTAssertFalse(store.isRunningOneClickUpdate)
    }

    func testLaunchGuardIsInitializedBeforeContentViewInstallsPresentationState() throws {
        let storeSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Stores/ScanStore.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(storeSource.contains(
            "isDebugAppUpdatePresentationFixtureActive =\n        DebugAppUpdatePresentationFixture.launchScenario != nil"
        ))
        XCTAssertTrue(storeSource.contains(
            "allowsLiveAppUpdateActions && !isLoadingAppUpdates"
        ))
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
#endif
