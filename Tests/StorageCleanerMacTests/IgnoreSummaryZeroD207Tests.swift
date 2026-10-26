import XCTest
@testable import StorageCleanerMac

/// D207 补: status lines and headlines name the ignored only when there are
/// some. "已忽略 0 项 · 所有应用都是最新版本" read as noise and broke the
/// updater's empty message; the details sheets keep the count beside their
/// other counts, zero included.
final class IgnoreSummaryZeroD207Tests: XCTestCase {
    func testStatusTextNamesTheIgnoredOnlyWhenThereAreSome() {
        XCTAssertEqual(IgnoreListSnapshot.appendingSummary(0, to: "A"), "A")
        XCTAssertEqual(IgnoreListSnapshot.appendingSummary(2, to: "A"), "A · " + IgnoreListSnapshot.summary(2))
    }

    func testTheUpdaterEmptyMessageAddsTheIgnoredAtTheEnd() {
        let current = AppUpdateTestFixtures.application(id: "current", status: .upToDate)
        let none = AppUpdateLightfieldPresentation(summary: .init(sessionID: UUID(), applications: [current])).emptyMessage
        XCTAssertFalse(none.contains(IgnoreListSnapshot.summary(0)))

        let ignored = AppUpdateTestFixtures.application(id: "ignored", bundleIdentifier: "com.example.ignored",
                                                        path: "/Applications/Ignored.app", status: .ignored)
        let some = AppUpdateLightfieldPresentation(summary: .init(sessionID: UUID(), applications: [current, ignored])).emptyMessage
        XCTAssertTrue(some.hasSuffix(" · " + IgnoreListSnapshot.summary(1)), some)
        XCTAssertFalse(some.hasPrefix(IgnoreListSnapshot.summary(1)), some)
    }

    func testTheLargeFileNoteOmitsZeroIgnored() {
        func note(ignored: Int) -> String {
            LargeFileListingSummary.make(candidates: [], threshold: .mib50, resultLimit: 80, reachedTimeLimit: false,
                                         reachedFolderLimit: false, lowerBoundPaths: [], ignoredItemCount: ignored).summary.note
        }
        XCTAssertFalse(note(ignored: 0).contains(IgnoreListSnapshot.summary(0)))
        XCTAssertTrue(note(ignored: 3).hasSuffix(" · " + IgnoreListSnapshot.summary(3)))
    }

    func testThePagesUseTheSharedRuleAndTheDetailsKeepZero() throws {
        func source(_ path: String) throws -> String {
            try String(contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
        }
        XCTAssertTrue(try source("Views/ApplicationsManager/ApplicationsOverviewView.swift").contains("if model.ignoredTotal > 0 {"))
        // D218＋旧值：was `.contains("IgnoreListSnapshot.appendingSummary(model.ignoredTotal, to: base)")`.
        // The Other Locations category counts its own ignored paths; the status line
        // still names them only when there are some, through the shared rule.
        let manager = try source("Views/ApplicationsManager/ApplicationsManagerView.swift")
        XCTAssertTrue(manager.contains("IgnoreListSnapshot.appendingSummary(ignored, to: base)"))
        XCTAssertTrue(manager.contains("model.category == .otherLocations ? model.otherApplications.ignoredCount : model.ignoredTotal"))
        XCTAssertTrue(try source("Views/ProjectArtifactView.swift")
            .contains("IgnoreListSnapshot.appendingSummary(result.session.metrics.ignoredItemCount, to:"))
        XCTAssertTrue(try source("Features/AppUpdates/Views/AppUpdatesView.swift")
            .contains("IgnoreListSnapshot.appendingSummary(summary.ignoredCount, to:"))
        // The details sheets list it with their other counts, zero included.
        XCTAssertTrue(try source("Views/CleanupScanViews.swift").contains("Text(session.metrics.ignoredSummary)"))
        XCTAssertTrue(try source("Views/FilesLightfield/DuplicateFilesLightfieldView.swift").contains("?? IgnoreListSnapshot.summary(0))"))
        XCTAssertTrue(try source("Features/MalwareScan/MalwareScanViews.swift").contains("IgnoreListSnapshot.summary(counts.ignored) + \" · \""))
    }
}
