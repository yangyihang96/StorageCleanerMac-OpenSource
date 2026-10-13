import Foundation
import XCTest
@testable import StorageCleanerMac

final class FileAnalysisTrashFollowupPresentationTests: XCTestCase {
    /// r2-fa-followups P2-3 and the main session's ruling (RULES §5): when
    /// the coordinator refuses, the notice above already says what happened;
    /// "Details" keeps only a code, and an error type of this app (or of the
    /// Swift runtime) is not named: 应用内部错误（代码 N）. System error domains
    /// keep their domain and code.
    func testMoveFailureDetailsNameSystemDomainsButNotThisAppsOwnTypes() {
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        let error = HeavyWorkCoordinator.Error.invalidLease(expectedOwner: .cleanup)
        let code = (error as NSError).code
        let detail = FileAnalysisTrashPresentation.moveFailureDetail(error)
        print("Details, coordinator error: \(detail)")
        XCTAssertEqual(detail, "错误域与错误码：应用内部错误（代码 \(code)）")
        for raw in ["StorageCleanerMac.", "HeavyWorkCoordinator", "Error:", "invalidLease", "expectedOwner", "cleanup", "(", "重试"] {
            XCTAssertFalse(detail.contains(raw), raw)
        }
        for repeated in ["后台任务的状态有变化", "没有移动任何项目"] {
            XCTAssertFalse(detail.contains(repeated), "The notice is not repeated: \(repeated)")
            XCTAssertTrue(FileAnalysisTrashPresentation.moveDidNotStart.contains(repeated))
        }
        let cancelled = FileAnalysisTrashPresentation.moveFailureDetail(CancellationError())
        XCTAssertTrue(cancelled.hasPrefix("错误域与错误码：应用内部错误（代码 "), cancelled)
        XCTAssertFalse(cancelled.contains("Swift."), cancelled)
        XCTAssertFalse(cancelled.contains("CancellationError"), cancelled)

        // System domains keep domain and code, also around an internal error.
        XCTAssertEqual(FileAnalysisTrashPresentation.moveFailureDetail(NSError(domain: NSPOSIXErrorDomain, code: 1)),
                       "错误域与错误码：NSPOSIXErrorDomain:1")
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                              userInfo: [NSUnderlyingErrorKey: error as NSError])
        XCTAssertEqual(FileAnalysisTrashPresentation.moveFailureDetail(wrapped),
                       "错误域与错误码：NSCocoaErrorDomain:513 > 应用内部错误（代码 \(code)）")
        XCTAssertEqual(FileAnalysisTrashPresentation.moveFailureDetail(CocoaError(.fileWriteNoPermission)),
                       "错误域与错误码：NSCocoaErrorDomain:513")

        let english = TrashLanguageScope(.english)
        defer { english.restore() }
        XCTAssertEqual(FileAnalysisTrashPresentation.moveFailureDetail(error),
                       "Error domains and codes: Internal error (code \(code))")
    }

    /// r2-fa-followups P2-3: on an external volume what is checked is whether
    /// the volume is read-only, and the page says so; iCloud keeps its words.
    /// The reasons this batch added read as short phrases on one line, the
    /// whole sentence on hover.
    func testTheVolumeIsNotCalledICloudAndTheNewReasonsAreShortPhrases() {
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        typealias P = FileAnalysisTrashPresentation
        XCTAssertEqual(P.checkingNotice(.volume), "正在确认卷状态…")
        XCTAssertEqual(P.checkingNotice(.iCloud), "正在确认 iCloud 状态…")
        XCTAssertEqual(P.checkingClickNotice(.volume, title: "big.zip"), "正在确认“big.zip”所在的卷是否只读，请稍候再勾选。")
        XCTAssertEqual(P.checkingClickNotice(.iCloud, title: "big.zip"), "正在确认“big.zip”所在位置是否由 iCloud 保管，请稍候再勾选。")
        let volumeHover = P.checkboxHelp(state: .checking(.volume))
        XCTAssertTrue(volumeHover.contains("只读"), volumeHover)
        XCTAssertFalse(volumeHover.contains("iCloud"), volumeHover)
        let iCloudHover = P.checkboxHelp(state: .checking(.iCloud))
        XCTAssertTrue(iCloudHover.contains("iCloud"), iCloudHover)
        XCTAssertFalse(iCloudHover.contains("只读"), iCloudHover)

        XCTAssertEqual(FileAnalysisTrashBlock.cloudStateUnknown.shortTitle, "云端状态未知")
        XCTAssertEqual(FileAnalysisTrashBlock.volumeStateUnknown.shortTitle, "卷状态未知")
        XCTAssertEqual(FileAnalysisTrashBlock.runningApplicationStateUnknown.shortTitle, "运行应用位置未知")
        XCTAssertEqual(FileAnalysisTrashBlock.protectedLocationsUnknown.shortTitle, "保护范围未知")
        XCTAssertTrue(FileAnalysisTrashBlock.cloudStateUnknown.explanation.hasPrefix("无法确认云端状态，暂不可选"))
        XCTAssertFalse(FileAnalysisTrashBlock.cloudStateUnknown.explanation.contains("只读"))
        for block in [FileAnalysisTrashBlock.cloudStateUnknown, .volumeStateUnknown,
                      .runningApplicationStateUnknown, .protectedLocationsUnknown] {
            let note = P.rowNote(state: .blocked(block))
            XCTAssertEqual(note, block.shortTitle)
            XCTAssertLessThanOrEqual(note?.count ?? 99, 8, "A phrase that fits one line: \(note ?? "")")
            XCTAssertFalse(note?.contains("，") ?? true, "A phrase, not a sentence")
            XCTAssertEqual(P.rowNoteLineLimit(state: .blocked(block)), 1)
            XCTAssertTrue(P.checkboxHelp(state: .blocked(block)).contains(block.explanation), "The whole sentence on hover")
        }
    }

    func testMoveFailureDetailsKeepDomainsAndCodesWithoutDescriptionsPathsOrAssociatedValues() {
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 13,
            userInfo: [NSLocalizedDescriptionKey: "internalEnum(expectedOwner: cleanup)",
                       NSFilePathErrorKey: "/Users/private/secret"])
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: "technical details"])
        XCTAssertEqual(FileAnalysisTrashPresentation.moveFailureDetail(error),
                       "错误域与错误码：NSCocoaErrorDomain:513 > NSPOSIXErrorDomain:13")
        XCTAssertFalse(FileAnalysisTrashPresentation.moveFailureDetail(error).contains("secret"))
        XCTAssertFalse(FileAnalysisTrashPresentation.moveFailureDetail(error).contains("internalEnum"))
    }

    func testAMountPointAppearingAfterReviewIsRecordedSpecificallyAndOtherItemsMove() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let mounts = RunningAppsStandIn()
        let analysis = try fixture.analyze()
        let environment = fixture.environment(mountPointPaths: { mounts.paths })
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let review = FileAnalysisTrashService.review(
            [try fixture.selection("Media", in: analysis.index), try fixture.selection("big.zip", in: analysis.index)],
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil)
        XCTAssertEqual(review.readyItems.count, 2)
        mounts.paths = [fixture.url("Media/Mounted").path]
        let outcome = await FileAnalysisTrashService.execute(review.items, index: analysis.index,
                                                              policy: policy, environment: environment)
        XCTAssertEqual(outcome.movedPaths, [fixture.url("big.zip").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("Media/photo.jpg").path))
        XCTAssertEqual(outcome.skipped.map(\.reason), [FileAnalysisTrashBlock.containsMountPoint.explanation])
        let report = try XCTUnwrap(try fixture.journal.load().first)
        XCTAssertEqual(report.items.first?.outcome, .skipped(.containsMountPoint))
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(CleanSkipReasonPresentation.title(.containsMountPoint), "含挂载点")
        XCTAssertNotEqual(CleanSkipReasonPresentation.title(.containsMountPoint),
                          CleanSkipReasonPresentation.title(.preflightNotApproved))
    }
}
