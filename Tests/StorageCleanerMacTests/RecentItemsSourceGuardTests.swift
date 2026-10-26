import Foundation
import XCTest

final class RecentItemsSourceGuardTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testSignalIsGuardedByExactNameCurrentUserPidAndSigtermWithFreshLookup() throws {
        let path = "Sources/StorageCleanerMac/Features/RecentItems/RecentItemsProcessController.swift"
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        let code = SwiftSourceScanning.compactKeepingLiterals(source)
        XCTAssertTrue(code.contains("currentUserID:uid_t=getuid()"))
        XCTAssertTrue(code.contains("process.pid>1&&process.name==\"sharedfilelistd\"&&process.userID==userID"))
        XCTAssertTrue(code.contains("forcandidateintryprocesses()whereSelf.isEligible(candidate,userID:currentUserID)"))
        XCTAssertTrue(code.contains("guardletcurrent=trylookup(candidate.pid),current==candidate,Self.isEligible(current,userID:currentUserID)else{continue}"))
        XCTAssertTrue(code.contains("signal(current.pid,SIGTERM)"))
        XCTAssertEqual(code.components(separatedBy: "Darwin.kill").count - 1, 1)
        XCTAssertTrue(code.contains("KERN_PROC_UID"))
        XCTAssertTrue(code.contains("KERN_PROC_PID"))
    }

    func testFeatureUsesExistingTrashRecorderAndNoPrivateUnarchiverDeletionOrProcessLaunch() throws {
        let folder = root.appendingPathComponent("Sources/StorageCleanerMac/Features/RecentItems")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let code = try files.filter { $0.pathExtension == "swift" }.map {
            SwiftSourceScanning.compactKeepingLiterals(try String(contentsOf: $0, encoding: .utf8))
        }.joined(separator: "\n")
        XCTAssertTrue(code.contains("RecordedTrashOperation.run("))
        for forbidden in ["NSKeyedUnarchiver", "removeItem(", "unlink(", "trashItem(", "Process(", "Shell.run(", "launchctl", "killall"] {
            XCTAssertFalse(code.contains(forbidden), forbidden)
        }
        XCTAssertTrue(code.contains("guardconfirmed,!selected.isEmptyelse{returnnil}"))
        XCTAssertTrue(code.contains("Task.sleep(for:.seconds(2))"))
        XCTAssertTrue(code.contains("awaitenvironment.waitForWriteback()"))
        XCTAssertEqual(code.components(separatedBy: "environment.scanner.scan()").count - 1, 1)
        XCTAssertFalse(code.contains("environment.scanner.readList("), "Verification reuses the one readback")
    }

    func testReadOnlyScanIsSuppressedInPresentationFixturesAndSheetsHaveReviewProbes() throws {
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/BrowserPrivacyWorkspaceView.swift"), encoding: .utf8)
        XCTAssertTrue(SwiftSourceScanning.compactKeepingLiterals(workspace)
            .contains("guard!FeaturePresentationDemo.isEnabled,!isPresentationFixtureelse{return}"))
        let sheet = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/CareStudio/CareStudioRecentItems.swift"), encoding: .utf8)
        for suffix in ["review", "confirmation", "result"] {
            XCTAssertTrue(sheet.contains("careStudio.protection.recentItems.\(suffix)"))
        }
        XCTAssertTrue(sheet.contains("store.selectedIDs.isEmpty"))
        XCTAssertTrue(sheet.contains(".toggleStyle(.checkbox)"))
    }
}
