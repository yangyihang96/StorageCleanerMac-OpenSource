import Foundation
import XCTest
@testable import StorageCleanerMac

/// Batch 3a: Operation History and the uninstall result show localized
/// explanations, never internal enum names such as `trashMoveRejected`.
final class OperationRecordLabelTests: XCTestCase {
    private let failureCodes: [CleanFailureCode] = [
        .persistenceFailed, .moveOutcomeUnknown, .trashMoveRejected, .trashMoveFailed, .quarantineMoveFailed,
        .metadataReadFailed, .planIntegrityFailed, .featureDisabled, .coordinatorBusy, .unexpected
    ]
    private let skipReasons: [CleanSkipReason] = [
        .preflightNotApproved, .itemMissing, .identityChanged, .entryKindChanged, .pathOutsideAllowedRoot,
        .symbolicLinkDetected, .volumeChanged, .volumeUnavailable, .volumeReadOnly, .permissionChanged,
        .excludedByUser, .cloudStateChanged, .relatedAppStillRunning, .rulesChanged, .measurementIncomplete,
        .duplicateEvidenceInvalid, .duplicateRetainedCopyChanged, .duplicateContentChanged, .candidateBecameActive,
        .changedSinceAnalysis, .containsMountPoint
    ]

    func testEveryFailureAndSkipHasALocalizedTitleInsteadOfItsEnumName() {
        // camelCase identifiers; a plain word such as "unexpected" can be prose.
        let rawNames = Set(failureCodes.map(\.rawValue) + skipReasons.map(\.rawValue))
            .filter { $0.contains(where: \.isUppercase) }
        for code in failureCodes {
            let title = CleanFailurePresentation.title(CleanFailure(code: code, detailCode: nil))
            XCTAssertFalse(title.isEmpty, code.rawValue)
            XCTAssertNotEqual(title, code.rawValue)
            XCTAssertFalse(rawNames.contains { title.contains($0) }, "\(code.rawValue): \(title)")
        }
        for reason in skipReasons {
            let title = CleanSkipReasonPresentation.title(reason)
            XCTAssertFalse(title.isEmpty, reason.rawValue)
            XCTAssertNotEqual(title, reason.rawValue)
            XCTAssertFalse(rawNames.contains { title.contains($0) }, "\(reason.rawValue): \(title)")
        }
    }

    func testEveryUninstallReasonHasItsOwnRecordLabel() {
        let reasons: [UninstallFailureReason] = [.systemRefused, .unsupportedLocation, .protectedApp, .locked,
            .authorizationIncomplete, .helperUnavailable, .changedSinceScan, .applicationNotConfirmed,
            .missing, .interrupted, .refused]
        let labels = reasons.compactMap(UninstallPresentation.recordLabel)
        XCTAssertEqual(labels.count, reasons.count)
        XCTAssertEqual(Set(labels).count, reasons.count, "Each reason reads differently")
        XCTAssertNil(UninstallPresentation.recordLabel(.other), "Unknown codes keep the generic failure title")
    }

    func testMountPointSkipHasAChineseRecordLabelAndRoundTrips() throws {
        let language = TrashLanguageScope(.zhHans)
        defer { language.restore() }
        XCTAssertEqual(CleanSkipReasonPresentation.title(.containsMountPoint), "含挂载点")
        let encoded = try JSONEncoder().encode(CleanSkipReason.containsMountPoint)
        XCTAssertEqual(try JSONDecoder().decode(CleanSkipReason.self, from: encoded), .containsMountPoint)
    }

    func testRecordViewsNoLongerPrintRawOutcomeNames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/StorageCleanerMac/Views")
        for file in ["ReversibleOperationsView.swift", "UninstallPreviewSheet.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains(".rawValue"), "\(file) must show localized text, not enum names")
        }
        let records = try String(contentsOf: root.appendingPathComponent("ReversibleOperationsView.swift"), encoding: .utf8)
        XCTAssertTrue(records.contains("CleanSkipReasonPresentation.recordLabel(reason)"))
        // D52：行为锁定共享标题和具体原因，避免依赖函数在文件中的先后顺序。
        for reason in skipReasons {
            let label = CleanSkipReasonPresentation.recordLabel(reason)
            if CleanSkipReasonPresentation.isStillInUse(reason) {
                XCTAssertTrue(label.hasPrefix(CleanupReportIssueGroup.stillInUse.title + " · "))
            }
            let detail = reason == .candidateBecameActive
                ? L10n.text("扫描后有新写入或变化", "Written or changed after the scan")
                : CleanSkipReasonPresentation.title(reason)
            XCTAssertTrue(label.hasSuffix(detail), "Record must preserve the specific reason: \(reason)")
        }
        XCTAssertTrue(records.contains("CleanFailurePresentation.title(failure)"))
    }
}
