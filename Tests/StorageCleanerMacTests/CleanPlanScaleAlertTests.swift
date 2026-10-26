import XCTest
@testable import StorageCleanerMac

/// D101 G13: when a run counts as unusually large, and what its summary
/// lists. Pure values only; the executor's check is covered in
/// CleanupExecutionSafetyTests, the store's confirmation in
/// CleanupStoreFollowUpTests and the sheet in UIConsistencyRegressionTests.
final class CleanPlanScaleAlertTests: XCTestCase {
    func testTheItemCountMarkIsMoreThanTenThousand() throws {
        let limit = CleanPlanScaleAlert.itemCountLimit
        XCTAssertEqual(limit, 10_000)
        XCTAssertNil(CleanPlanScaleAlert(items: items(limit), usedBytes: [:]) { $0 })

        let alert = try XCTUnwrap(CleanPlanScaleAlert(items: items(limit + 1), usedBytes: [:]) { $0 })
        XCTAssertTrue(alert.exceedsItemCount)
        XCTAssertEqual(alert.itemCount, limit + 1)
        XCTAssertEqual(alert.bytes, Int64(limit + 1))
        XCTAssertEqual(alert.largeVolumeShares, [], "The volume's use is unknown here")
    }

    func testTheVolumeMarkIsMoreThanHalfTheUsedSpace() throws {
        let run = [item(bytes: 60), item(bytes: 40)]
        XCTAssertNil(CleanPlanScaleAlert(items: run, usedBytes: ["volume-a": 200]) { $0 }, "Exactly half")

        let alert = try XCTUnwrap(CleanPlanScaleAlert(items: run, usedBytes: ["volume-a": 199]) { $0 })
        XCTAssertFalse(alert.exceedsItemCount)
        XCTAssertEqual(alert.itemCount, 2)
        XCTAssertEqual(alert.bytes, 100)
        XCTAssertEqual(alert.largeVolumeShares, [
            .init(volumeIdentifier: "volume-a", plannedBytes: 100, usedBytes: 199)
        ])

        // Without a reading for the volume, only the count is judged.
        XCTAssertNil(CleanPlanScaleAlert(items: run, usedBytes: [:]) { $0 })
        XCTAssertNil(CleanPlanScaleAlert(items: run, usedBytes: ["volume-a": 0]) { $0 })
        XCTAssertNil(CleanPlanScaleAlert(items: run, usedBytes: ["volume-b": 1]) { $0 })
    }

    /// Each volume is held to its own used space, not to the run's total.
    func testEachVolumeIsJudgedOnItsOwnUsedSpace() throws {
        let run = [item(bytes: 300, volume: "volume-a"), item(bytes: 60, volume: "volume-b"),
                   item(bytes: 90, volume: "volume-c")]
        let used: [String: Int64] = ["volume-a": 800, "volume-b": 100, "volume-c": 100]

        let alert = try XCTUnwrap(CleanPlanScaleAlert(items: run, usedBytes: used) { $0 })
        XCTAssertEqual(alert.bytes, 450)
        XCTAssertEqual(alert.largeVolumeShares, [
            .init(volumeIdentifier: "volume-c", plannedBytes: 90, usedBytes: 100),
            .init(volumeIdentifier: "volume-b", plannedBytes: 60, usedBytes: 100)
        ], "Largest first; volume-a's 300 is not more than half its 800 in use, though the run's 450 is")

        XCTAssertNil(CleanPlanScaleAlert(items: [run[0]], usedBytes: used) { $0 })
    }

    /// The summary names the three rules with the most bytes; a tie goes to
    /// the rule with more items.
    func testTheSummaryListsTheThreeLargestRules() throws {
        let run = [item(bytes: 50, ruleID: "r2"),
                   item(bytes: 20, ruleID: "r3"), item(bytes: 20, ruleID: "r3"),
                   item(bytes: 10, ruleID: "r1"), item(bytes: 10, ruleID: "r1"), item(bytes: 10, ruleID: "r1"),
                   item(bytes: 30, ruleID: "r5"),
                   item(bytes: 5, ruleID: "r4")]

        let alert = try XCTUnwrap(CleanPlanScaleAlert(items: run, usedBytes: ["volume-a": 1]) { "title-\($0)" })
        XCTAssertEqual(CleanPlanScaleAlert.listedRuleLimit, 3)
        XCTAssertEqual(alert.largestRules, [
            .init(ruleID: "r2", title: "title-r2", itemCount: 1, bytes: 50),
            .init(ruleID: "r3", title: "title-r3", itemCount: 2, bytes: 40),
            .init(ruleID: "r1", title: "title-r1", itemCount: 3, bytes: 30)
        ])
    }

    func testTheSummaryTextNamesEachReason() throws {
        let countOnly = try XCTUnwrap(CleanPlanScaleAlert(
            items: items(CleanPlanScaleAlert.itemCountLimit + 1), usedBytes: [:]) { $0 })
        let countText = CleanPlanScaleAlertPresentation.summary(countOnly)
        XCTAssertTrue(countText.contains(L10n.text("将处理 \(10_001.formatted()) 项", "handles \(10_001.formatted()) item(s)")))
        XCTAssertTrue(countText.contains(L10n.text("超过单次 \(10_000.formatted()) 项", "more than \(10_000.formatted()) items")))
        XCTAssertFalse(countText.contains(L10n.text("已用空间", "used space")))

        let volumeOnly = try XCTUnwrap(CleanPlanScaleAlert(
            items: [item(bytes: 3 << 30)], usedBytes: ["volume-a": 4 << 30]) { $0 })
        let volumeText = CleanPlanScaleAlertPresentation.summary(volumeOnly)
        // D178: decimal, "3.22 GB" and "4.29 GB" (was `ByteFormat.string`, binary: "3.0 GiB", "4.0 GiB").
        XCTAssertTrue(volumeText.contains(ByteFormat.storageString(3 << 30)))
        XCTAssertTrue(volumeText.contains(ByteFormat.storageString(4 << 30)))
        XCTAssertTrue(volumeText.contains(L10n.text("已用空间", "used space")))
        XCTAssertFalse(volumeText.contains(L10n.text("超过单次", "the mark for one run")))
    }

    private func items(_ count: Int) -> [CleanPlanItem] {
        (0..<count).map { _ in item(bytes: 1) }
    }

    private func item(bytes: Int64, volume: String = "volume-a", ruleID: String = "system.user-caches") -> CleanPlanItem {
        let url = URL(fileURLWithPath: "/Fixture/\(UUID().uuidString)")
        let snapshot = FileSnapshot(
            identity: FileIdentity(deviceID: 1, inode: 1, entryKind: .regularFile, creationTimeNanoseconds: 1),
            standardizedPath: url.path, volumeIdentifier: volume, logicalSizeBytes: bytes,
            allocatedSizeBytes: bytes, modificationTimeNanoseconds: 1, isWritableVolume: true,
            isCloudItem: false, isCloudPlaceholder: false, hasSymbolicLinkComponent: false)
        return CleanPlanItem(id: UUID(), candidateID: ScanCandidateID(), ruleID: ruleID,
            ruleSelectionPolicyVersion: 1, sourceURL: url, allowedRootURL: url.deletingLastPathComponent(),
            expectedSnapshot: snapshot, action: .moveToTrash, riskLevel: .safe,
            executionEligibility: .eligible, measurementCompleteness: .complete, requiredClosedBundleIDs: [],
            reasonCode: "g13", reasonCodes: ["g13"], explicitUserSelection: true,
            verifiedDuplicateEvidence: nil, protectedRetainedCopies: [])
    }
}
