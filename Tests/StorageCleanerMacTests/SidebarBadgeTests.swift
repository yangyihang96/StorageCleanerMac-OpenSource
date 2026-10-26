import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Report §4 item 16 (CleanMyMac's sidebar marks, `1比1对照-20261023/cmm/11`–`24`,
/// `cmm2/01`): how far a module's work is, Smart Scan's results waiting, and
/// a module's results. The marks themselves are drawn by
/// `CareStudioModuleShellRenderTests.testRendersTheSidebarMarksForReview`.
@MainActor
final class SidebarBadgeTests: XCTestCase {
    private func badge(_ family: CareStudioFamily, _ change: (inout SidebarBadgeInputs) -> Void) -> SidebarBadge? {
        var inputs = SidebarBadgeInputs()
        change(&inputs)
        return SidebarBadge.badge(for: family, inputs)
    }

    /// Smart Scan: the sector while it scans (`cmm/11`–`13`), the yellow dot
    /// while its results wait (`cmm/14`, `15`) and nothing after Start Over
    /// (`cmm/17`) or a finished run.
    func testSmartScanShowsItsScanThenItsWaitingResults() {
        XCTAssertEqual(badge(.smartCare) { $0.smartCareStage = .scanning(.protection); $0.smartCareFraction = 0.2 },
                       .progress(0.2))
        XCTAssertEqual(badge(.smartCare) { $0.smartCareStage = .running(.cleanup) }, .progress(nil))
        XCTAssertEqual(badge(.smartCare) { $0.smartCareStage = .results }, .attention)
        XCTAssertNil(badge(.smartCare) { $0.smartCareStage = .finished })
        XCTAssertNil(badge(.smartCare) { _ in })
        // The junk scan on its own (the classic Smart Scan page).
        XCTAssertEqual(badge(.smartCare) { $0.mainScanFamily = .smartCare; $0.mainScanFraction = 0.5 }, .progress(0.5))
    }

    /// The selected parts that ended, as the scanning page's ring counts
    /// them (`SmartCareScanningPage`), so the sidebar and the page agree.
    func testSmartScanProgressCountsTheEndedPartsAsItsPageDoes() throws {
        let fraction = SidebarBadgeInputs.smartCareFraction
        XCTAssertEqual(try XCTUnwrap(fraction([.done, .scanning, .waiting, .waiting, .off])), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(fraction([.stopped, .skipped("x"), .failed("y"), .done])), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(fraction([.scanning, .off, .off])), 0, accuracy: 0.0001)
        XCTAssertNil(fraction([.off, .off]))
        XCTAssertNil(fraction([]))
    }

    /// A module at work shows its progress before its results; its results
    /// show the white dot, on the current module and the others alike.
    func testAModuleShowsItsWorkBeforeItsResults() {
        XCTAssertEqual(badge(.cleanup) { $0.mainScanFamily = .cleanup; $0.mainScanFraction = 0.4; $0.cleanupShowsResults = true },
                       .progress(0.4))
        XCTAssertEqual(badge(.cleanup) { $0.cleanupShowsResults = true }, .results)
        XCTAssertNil(badge(.cleanup) { $0.mainScanFamily = .smartCare }, "Smart Scan's junk scan is Smart Scan's")

        XCTAssertEqual(badge(.protection) { $0.malwareScanning = true; $0.protectionShowsResults = true }, .progress(nil),
                       "the malware scan goes on behind the results (cmm/24)")
        XCTAssertEqual(badge(.protection) { $0.privacyScanning = true }, .progress(nil))
        XCTAssertEqual(badge(.protection) { $0.protectionShowsResults = true }, .results)

        XCTAssertEqual(badge(.performance) { $0.startupLoading = true; $0.startupScanned = true }, .progress(nil))
        XCTAssertEqual(badge(.performance) { $0.startupScanned = true }, .results)
        XCTAssertEqual(badge(.applications) { $0.appsLoading = true }, .progress(nil))
        XCTAssertEqual(badge(.applications) { $0.appsScanned = true }, .results)
        XCTAssertEqual(badge(.clutter) { $0.duplicatesScanning = true }, .progress(nil))
        XCTAssertEqual(badge(.clutter) { $0.duplicatesScanned = true }, .results)
        XCTAssertEqual(badge(.spaceMap) { $0.storageAnalyzing = true; $0.storageAnalyzed = true }, .progress(nil))
        XCTAssertEqual(badge(.spaceMap) { $0.storageAnalyzed = true }, .results)
        XCTAssertEqual(badge(.cloudCleanup) { $0.cloudScanning = true }, .progress(nil))
        XCTAssertEqual(badge(.cloudCleanup) { $0.cloudScanned = true }, .results)
        XCTAssertEqual(badge(.myTools) { $0.largeFilesScanning = true; $0.largeFilesFraction = 0.3 }, .progress(0.3))
        XCTAssertNil(badge(.myTools) { $0.storageAnalyzed = true; $0.appsScanned = true })
        for family in CareStudioFamily.allCases where family != .smartCare {
            XCTAssertNil(badge(family) { _ in }, "\(family) has nothing to show")
        }
        XCTAssertNil(badge(.myActivity) { $0.largeFilesScanning = true; $0.cleanupShowsResults = true })
    }

    /// While Smart Scan scans a part, only Smart Scan shows it (`cmm/11`–`13`);
    /// Protection's own malware scan still shows on Protection.
    func testThePartSmartScanScansShowsOnSmartScanOnly() {
        XCTAssertNil(badge(.protection) { $0.smartCareStage = .scanning(.protection); $0.privacyScanning = true })
        XCTAssertEqual(badge(.protection) {
            $0.smartCareStage = .scanning(.protection); $0.privacyScanning = true; $0.malwareScanning = true
        }, .progress(nil))
        XCTAssertNil(badge(.performance) { $0.smartCareStage = .scanning(.performance); $0.startupLoading = true })
        XCTAssertNil(badge(.applications) { $0.smartCareStage = .scanning(.applications); $0.appsLoading = true })
        XCTAssertNil(badge(.clutter) { $0.smartCareStage = .scanning(.clutter); $0.duplicatesScanning = true })
        XCTAssertEqual(badge(.clutter) { $0.smartCareStage = .scanning(.performance); $0.duplicatesScanning = true },
                       .progress(nil), "another part's module is not Smart Scan's now")
    }

    /// The scanning pages' rule: a fraction only where the scan knows its
    /// total.
    func testProgressFractionsAreTheScanPagesOwn() throws {
        func progress(_ kind: ScanProgressKind, groups: (Int, Int)) -> DiskScanProgress {
            DiskScanProgress(currentGroupTitle: "Caches", completedGroupCount: groups.0, totalGroupCount: groups.1,
                             groups: [], progressKind: kind)
        }
        let known = progress(.determinate, groups: (1, 4))
        XCTAssertEqual(try XCTUnwrap(SidebarBadgeInputs.fraction(known)), 0.25, accuracy: 0.0001)
        XCTAssertNil(SidebarBadgeInputs.fraction(progress(.indeterminate, groups: (1, 4))))
    }

    /// The inputs follow the stores, and each page's own choice of landing
    /// or results.
    func testTheMarksFollowTheStores() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let smartCare = SmartCareCoordinator.of(store)
        let privacy = BrowserPrivacyStore()
        let malware = MalwareScanStore(scanner: SidebarBadgeMalwareScanner())
        func badges() -> [CareStudioFamily: SidebarBadge] {
            let inputs = SidebarBadgeInputs(store: store, smartCare: smartCare, privacy: privacy, malware: malware,
                                            cloud: CloudCleanupModel.shared)
            var badges: [CareStudioFamily: SidebarBadge] = [:]
            // Cloud Cleanup's model is the app's one; other tests may scan with it.
            for family in CareStudioFamily.allCases where family != .cloudCleanup {
                badges[family] = SidebarBadge.badge(for: family, inputs)
            }
            return badges
        }
        XCTAssertEqual(badges(), [:], "nothing scanned, nothing to show")

        store.isLoadingStartupItems = true
        XCTAssertEqual(badges(), [.performance: .progress(nil)])
        store.isLoadingStartupItems = false
        store.hasScannedStartupItems = true
        store.hasScannedInstalledApps = true
        XCTAssertEqual(badges(), [.performance: .results, .applications: .results])

        malware.startScan()
        await malware.waitUntilIdle()
        XCTAssertEqual(badges()[.protection], .results, "the malware result opens Protection's results page")
        malware.startOver()
        XCTAssertNil(badges()[.protection])

        // Scan, then Stop before the first part starts: the results page waits.
        smartCare.start()
        smartCare.stop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while smartCare.stage != .results, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(badges()[.smartCare], .attention)
        smartCare.reset()
        XCTAssertNil(badges()[.smartCare], "Start Over")
    }

    func testTheMarksNameThemselves() {
        XCTAssertTrue(SidebarBadge.progress(0.42).accessibilityText.contains("42%"))
        XCTAssertFalse(SidebarBadge.progress(nil).accessibilityText.contains("%"))
        XCTAssertNotEqual(SidebarBadge.attention.accessibilityText, SidebarBadge.results.accessibilityText)
    }

    /// The done part grows clockwise from twelve o'clock (`cmm/11`: a quarter
    /// fills the top right).
    func testTheSectorGrowsClockwiseFromTwelve() {
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let quarter = SidebarBadgeSector(fraction: 0.25).path(in: rect)
        XCTAssertTrue(quarter.contains(CGPoint(x: 12, y: 4)), "top right")
        XCTAssertFalse(quarter.contains(CGPoint(x: 4, y: 4)), "top left")
        XCTAssertFalse(quarter.contains(CGPoint(x: 12, y: 12)), "bottom right")
        let most = SidebarBadgeSector(fraction: 0.9).path(in: rect)
        XCTAssertTrue(most.contains(CGPoint(x: 4, y: 12)), "bottom left")
        XCTAssertFalse(most.contains(CGPoint(x: 6.5, y: 1.5)), "just before twelve")
        XCTAssertTrue(SidebarBadgeSector(fraction: 0).path(in: rect).isEmpty)
        XCTAssertTrue(SidebarBadgeSector(fraction: 1).path(in: rect).contains(CGPoint(x: 4, y: 4)))
    }
}

/// A malware scan that checks three files and finds nothing.
private struct SidebarBadgeMalwareScanner: MalwareScanning {
    func scan(progress: @escaping @Sendable (MalwareScanProgress) -> Void) async -> MalwareScanOutcome {
        MalwareScanOutcome(checkedFiles: 3)
    }
}
