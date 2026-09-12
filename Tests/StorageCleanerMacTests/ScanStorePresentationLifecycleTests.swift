import Foundation
import XCTest

final class ScanStorePresentationLifecycleTests: XCTestCase {
    func testRecoveryTaskReleasesItsStateBeforeCheckingWhetherReportStillExists() throws {
        let source = try scanStoreSource()
        let recovery = try segment(
            source,
            from: "func confirmRestoreLatestV2Cleanup() {",
            to: "private func cleanupExecutionContext("
        )

        let cleanupIndex = try XCTUnwrap(recovery.range(of: "defer {"))
        let reportGuardIndex = try XCTUnwrap(recovery.range(of: "self.lastCleanReport?.id == report.id"))

        XCTAssertLessThan(cleanupIndex.lowerBound, reportGuardIndex.lowerBound)
        XCTAssertTrue(recovery.contains("self.cleanupRecoveryTask = nil"))
        XCTAssertTrue(recovery.contains("self.isRestoringV2Cleanup = false"))
        XCTAssertTrue(recovery.contains("if self.cleanupRecoveryGeneration == recoveryGeneration"))
    }

    func testCompletedScanPublishesTokenBoundPhasesWithoutSleepingBusinessWork() throws {
        let source = try scanStoreSource()

        XCTAssertTrue(source.contains("@Published private(set) var scanPresentation = ScanPresentation()"))
        XCTAssertTrue(source.contains("beginScanPresentation(sessionID: generation)"))
        XCTAssertTrue(source.contains("@Published private(set) var isFinalizingMainScan = false"))
        XCTAssertTrue(source.contains("private enum SmartScanPresentationTiming"))
        XCTAssertTrue(source.contains("static let preparingMinimum: TimeInterval = 0.20"))
        XCTAssertTrue(source.contains("static let scanningMinimum: TimeInterval = 0.70"))
        XCTAssertTrue(source.contains("static let finalizingMinimum: TimeInterval = 0.25"))
        XCTAssertTrue(source.contains("static let cleanupVerificationMinimum: TimeInterval = 0.25"))
        XCTAssertTrue(source.contains("finishScanPresentation("))
        XCTAssertTrue(source.contains("finishCleanupVerificationPresentation("))
        XCTAssertTrue(source.contains("scanPresentationSessionID == presentationSessionID"))
        XCTAssertTrue(source.contains("mainScanGeneration == generation"))
        XCTAssertFalse(source.contains("Task.sleep(nanoseconds: 400_000_000)"))
    }

    func testProductionAppUpdatesPageConsumesStoreBatchProjection() throws {
        let storeSource = try scanStoreSource()
        let viewSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(storeSource.contains("@Published private(set) var appUpdateScanState"))
        XCTAssertTrue(storeSource.contains("var appUpdateOrchestratorState: UpdateOrchestratorState"))
        XCTAssertTrue(storeSource.contains("UpdateOrchestratorState.project("))
        XCTAssertTrue(viewSource.contains("store.appUpdateOrchestratorState"))
        XCTAssertTrue(viewSource.contains("AppUpdateOrchestratorStatusBanner("))
        XCTAssertTrue(viewSource.contains("batchState: store.appUpdateOrchestratorState"))
    }

    private func scanStoreSource() throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )
    }

    private func segment(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
