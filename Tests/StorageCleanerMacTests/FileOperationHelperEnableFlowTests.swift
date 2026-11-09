import Foundation
import ServiceManagement
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D229 (review P1-1): the formal 2.0.1 install had never registered the
/// file-operation helper, so Performance and Smart Scan could not read login
/// items and only said "Login Items Not Read". The explicit, confirmed
/// "Enable Background Helper" registers it; scans still never do (D177).
@MainActor
final class FileOperationHelperEnableFlowTests: XCTestCase {
    /// The registration as the fake service reports it; read off the main thread.
    private final class Service: @unchecked Sendable {
        private let lock = NSLock()
        private var current: FileOperationHelperStatus
        private var trustedValue: Bool
        init(_ status: FileOperationHelperStatus, trusted: Bool = true) {
            current = status
            trustedValue = trusted
        }
        var status: FileOperationHelperStatus {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
        var trusted: Bool { lock.withLock { trustedValue } }
    }

    private final class Recorder {
        var registrations = 0
        var approvalSettingsOpened = 0
        var listReads = 0
    }

    private func enabler(_ service: Service, _ recorder: Recorder,
                         register: @escaping @MainActor @Sendable (Service) throws -> Void) -> FileOperationHelperEnabler {
        nonisolated(unsafe) let recorder = recorder
        return FileOperationHelperEnabler(.init(
            readStatus: { service.status },
            bundledHelperIsTrusted: { service.trusted },
            register: {
                recorder.registrations += 1
                try register(service)
            },
            openApprovalSettings: { recorder.approvalSettingsOpened += 1 }))
    }

    private func readList(_ recorder: Recorder) -> @MainActor @Sendable () -> Void {
        nonisolated(unsafe) let recorder = recorder
        return { recorder.listReads += 1 }
    }

    func testNotRegisteredBecomesEnabledAndReadsTheListOnce() async {
        let service = Service(.notRegistered)
        let recorder = Recorder()
        let sut = enabler(service, recorder) { $0.status = .enabled }
        let outcome = await sut.enable(onEnabled: readList(recorder))
        XCTAssertEqual(outcome, .enabled)
        XCTAssertEqual(sut.status, .enabled)
        XCTAssertEqual(recorder.registrations, 1)
        XCTAssertEqual(recorder.listReads, 1)
        XCTAssertEqual(recorder.approvalSettingsOpened, 0)
        XCTAssertFalse(sut.isEnabling)
    }

    func testRegistrationAwaitingApprovalOpensLoginItemsAndReadsAfterApproval() async {
        let service = Service(.notRegistered)
        let recorder = Recorder()
        let sut = enabler(service, recorder) {
            $0.status = .requiresApproval
            throw AuthorizedMoveError.approvalRequired
        }
        let outcome = await sut.enable(onEnabled: readList(recorder))
        XCTAssertEqual(outcome, .awaitingApproval)
        XCTAssertEqual(sut.status, .requiresApproval)
        XCTAssertEqual(recorder.registrations, 1)
        XCTAssertEqual(recorder.approvalSettingsOpened, 1)
        XCTAssertEqual(recorder.listReads, 0, "nothing is read before the user approves")
        // The user turns the switch on in System Settings and comes back.
        await sut.refresh()
        XCTAssertEqual(recorder.listReads, 0)
        service.status = .enabled
        await sut.refresh()
        XCTAssertEqual(sut.outcome, .enabled)
        XCTAssertEqual(recorder.listReads, 1)
        await sut.refresh()
        XCTAssertEqual(recorder.listReads, 1, "the approval finishes once")
    }

    func testAlreadyRegisteredHelperIsNotRegisteredAgainOnlyApprovalOpens() async {
        let service = Service(.requiresApproval)
        let recorder = Recorder()
        let sut = enabler(service, recorder) { _ in XCTFail("an awaiting helper is not registered again") }
        let outcome = await sut.enable(onEnabled: readList(recorder))
        XCTAssertEqual(outcome, .awaitingApproval)
        XCTAssertEqual(recorder.registrations, 0)
        XCTAssertEqual(recorder.approvalSettingsOpened, 1)
    }

    func testFailedRegistrationReportsWhyAndReadsNothing() async {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let service = Service(.notRegistered)
        let recorder = Recorder()
        let sut = enabler(service, recorder) { _ in
            throw NSError(domain: "UninstallAuthorization.helper-registration", code: 1,
                          userInfo: [NSUnderlyingErrorKey: NSError(domain: "SMAppServiceErrorDomain", code: 22)])
        }
        let outcome = await sut.enable(onEnabled: readList(recorder))
        guard case .failed(let message)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertTrue(message.contains("SMAppServiceErrorDomain 22"), message)
        XCTAssertEqual(sut.status, .notRegistered)
        XCTAssertEqual(recorder.listReads, 0)
        XCTAssertEqual(recorder.approvalSettingsOpened, 0)
    }

    func testUntrustedOrMissingHelperIsNeverRegistered() async {
        for service in [Service(.notRegistered, trusted: false), Service(.unavailable)] {
            let recorder = Recorder()
            let sut = enabler(service, recorder) { _ in XCTFail("registered an untrusted or missing helper") }
            let outcome = await sut.enable(onEnabled: readList(recorder))
            XCTAssertEqual(outcome, .failed(FileOperationHelperEnabler.unavailableMessage))
            XCTAssertEqual(recorder.registrations, 0)
            XCTAssertEqual(recorder.listReads, 0)
        }
    }

    func testEnabledHelperIsOnlyReadAgain() async {
        let service = Service(.enabled)
        let recorder = Recorder()
        let sut = enabler(service, recorder) { _ in XCTFail("an enabled helper is not registered again") }
        let outcome = await sut.enable(onEnabled: readList(recorder))
        XCTAssertEqual(outcome, .enabled)
        XCTAssertEqual(recorder.registrations, 0)
        XCTAssertEqual(recorder.listReads, 1)
    }

    func testServiceStatusMapping() {
        XCTAssertEqual(FileOperationHelperStatus(service: .enabled, bundled: true), .enabled)
        XCTAssertEqual(FileOperationHelperStatus(service: .requiresApproval, bundled: true), .requiresApproval)
        XCTAssertEqual(FileOperationHelperStatus(service: .notRegistered, bundled: true), .notRegistered)
        XCTAssertEqual(FileOperationHelperStatus(service: .notFound, bundled: true), .notRegistered)
        for status in [SMAppService.Status.enabled, .requiresApproval, .notRegistered, .notFound] {
            XCTAssertEqual(FileOperationHelperStatus(service: status, bundled: false), .unavailable)
        }
    }

    func testUnreadReasonNamesTheHelperStateAndTheWayOutInBothLanguages() {
        var coverage = StartupCoverageReport.empty
        coverage.sources = [.init(source: .backgroundTaskDiagnostic, identifier: "helper", discoveredCount: 0,
                                  errorDescription: "Fixture read error")]
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            var reading = StartupReadPresentation(coverage: coverage)
            XCTAssertEqual(reading.unreadReason, "Fixture read error", "no helper status: the read's own error, as before")
            reading.helper = .enabled
            XCTAssertEqual(reading.unreadReason, "Fixture read error", "an enabled helper is not the reason")
            for status in [FileOperationHelperStatus.notRegistered, .requiresApproval, .unavailable] {
                reading.helper = status
                XCTAssertEqual(reading.unreadReason, status.unreadLoginReason)
                XCTAssertEqual(reading.loginDetail, status.unreadLoginReason)
            }
            reading.helper = .notRegistered
            XCTAssertTrue(reading.unreadReason.contains(language == .zhHans ? "启用后台助手" : "Enable it"))
            XCTAssertEqual(FileOperationHelperStatus.notRegistered.actionTitle, language == .zhHans ? "启用后台助手" : "Enable Helper")
            XCTAssertEqual(FileOperationHelperStatus.requiresApproval.actionTitle, language == .zhHans ? "打开登录项" : "Open Login Items")
            XCTAssertNil(FileOperationHelperStatus.enabled.actionTitle)
            XCTAssertNil(FileOperationHelperStatus.unavailable.actionTitle)
            // D229＋旧值“…登录项要用“完整扫描”读取。”: the error names no button.
            let error = BackgroundTaskManagementScanError.helperUnavailable.errorDescription ?? ""
            XCTAssertFalse(error.contains("完整扫描"), error)
            XCTAssertFalse(error.contains("Full Scan"), error)
        }
    }

    func testUnreadLoginTileLeadsWithTheReasonAndTheEnableButton() throws {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let summary = StartupItemsPresentation.make(items: [], query: "", category: .all, status: .all, source: .all,
                                                    includeAppleSystem: false, sort: .recommended, includeTechnicalDetails: false)
        let leading = CareStudioTileModel(id: "maintenance", module: .startup, title: "fixture", systemImage: "wrench",
                                          reviewTitle: "查看", onReview: {})
        var performed = 0
        let offer = CareStudioStartupHelperAction(status: .notRegistered) { performed += 1 }
        let unread = CareStudioStartupResultsPage.tiles(summary, coverage: .empty, helper: offer,
                                                        leadingTiles: [leading]) { _ in {} }
        XCTAssertEqual(unread.map(\.id), ["login", "maintenance", "background", "updates"])
        let login = try XCTUnwrap(unread.first)
        XCTAssertEqual(login.title, "没读到登录项")
        XCTAssertEqual(login.detail, FileOperationHelperStatus.notRegistered.unreadLoginReason)
        XCTAssertEqual(login.cleanTitle, "启用后台助手")
        XCTAssertTrue(login.cleanEnabled)
        XCTAssertNotNil(login.reviewTint)
        XCTAssertEqual(login.reviewTitle, "查看", "Review stays next to the new button")
        login.onClean?()
        XCTAssertEqual(performed, 1)

        let approval = CareStudioStartupResultsPage.tiles(summary, coverage: .empty,
            helper: CareStudioStartupHelperAction(status: .requiresApproval) {}, leadingTiles: [leading]) { _ in {} }
        XCTAssertEqual(approval.first?.cleanTitle, "打开登录项")
        let busy = CareStudioStartupResultsPage.tiles(summary, coverage: .empty,
            helper: CareStudioStartupHelperAction(status: .notRegistered, isBusy: true) {}, leadingTiles: [leading]) { _ in {} }
        XCTAssertEqual(busy.first?.cleanTitle, "正在启用…")
        XCTAssertEqual(busy.first?.cleanEnabled, false)
        let unknown = CareStudioStartupResultsPage.tiles(summary, coverage: .empty, helper: nil,
                                                         leadingTiles: [leading]) { _ in {} }
        XCTAssertEqual(unknown.first?.id, "login")
        XCTAssertNil(unknown.first?.cleanTitle, "no button until the helper's status is known")

        var coverage = StartupCoverageReport.empty
        coverage.managedItemCoverageAvailable = true
        let read = CareStudioStartupResultsPage.tiles(summary, coverage: coverage, helper: offer,
                                                      leadingTiles: [leading]) { _ in {} }
        XCTAssertEqual(read.map(\.id), ["maintenance", "login", "background", "updates"], "item 13's order when read")
        XCTAssertNil(read[1].cleanTitle)
        XCTAssertNil(read[1].reviewTint)
    }

    /// D177 stands: no scan path registers the helper. Only the confirmed
    /// button (and the confirmed operations that already did) reach `prepareHelper`.
    func testScanPathsNeverRegisterTheHelper() throws {
        let sources = try SwiftSourceScanning.sources()
        let callers = sources.filter { $0.value.contains("AuthorizedApplicationMover.shared.prepareHelper(") }.keys.sorted()
        XCTAssertEqual(callers, [
            "Sources/StorageCleanerMac/Services/AppUpdateProtectedApplicationAuthorization.swift",
            "Sources/StorageCleanerMac/Services/FileOperationHelperEnabler.swift",
            "Sources/StorageCleanerMac/Services/SystemCacheService.swift",
        ])
        let scanning = sources.filter {
            $0.key.hasPrefix("Sources/StorageCleanerMac/Features/StartupItems/Scanning/")
                || $0.key.hasPrefix("Sources/StorageCleanerMac/Stores/")
                || $0.key == "Sources/StorageCleanerMac/Models/SmartCareModule.swift"
                || $0.key == "Sources/StorageCleanerMac/Services/HelperBackgroundTaskInventory.swift"
        }
        XCTAssertFalse(scanning.isEmpty)
        for (path, raw) in scanning {
            let code = SwiftSourceScanning.code(raw)
            for forbidden in ["prepareHelper", "FileOperationHelperEnabler", "SMAppService.daemon", ".register()"] {
                XCTAssertFalse(code.contains(forbidden), "\(path): \(forbidden)")
            }
        }
        // The views call `enable` only from the confirmation or, for a helper
        // already registered, to open Login Items.
        let utilities = try XCTUnwrap(sources["Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"])
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "helperEnabler.enable", in: utilities), 1)
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "enableHelper()", in: utilities), 3)
        XCTAssertTrue(utilities.contains(".fileOperationHelperEnableConfirmation(isPresented: $confirmsHelperEnable) { enableHelper() }"))
        XCTAssertTrue(utilities.contains("if status == .requiresApproval { enableHelper() } else { confirmsHelperEnable = true }"))
        let access = try XCTUnwrap(sources["Sources/StorageCleanerMac/Views/Settings/SettingsAccess.swift"])
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "fileOperationHelper.enable", in: access), 1)
        XCTAssertTrue(access.contains(".fileOperationHelperEnableConfirmation(isPresented: $confirmsFileOperationHelper) { enableFileOperationHelper() }"))
        let refresh = try r2SourceDeclaration("func refreshAccessStatus()", in: access)
        XCTAssertTrue(refresh.contains("await fileOperationHelper.refresh()"))
        XCTAssertFalse(refresh.contains(".enable"))
        let smartCare = try XCTUnwrap(sources["Sources/StorageCleanerMac/Views/CareStudio/CareStudioSmartCare.swift"])
        XCTAssertTrue(smartCare.contains("reading.helper = FileOperationHelperEnabler.shared.status"))
        XCTAssertFalse(smartCare.contains(".enable"))
    }

    /// D229＋旧值“系统后台项读取诊断：<原因>”: the Startup Manager's button help
    /// says what the button does, then why the last read failed.
    func testManagerFooterOffersTheSameWayOutAndExplainsItsButton() throws {
        let utilities = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"), encoding: .utf8)
        XCTAssertTrue(utilities.contains("再次读取 macOS 登录项与后台任务数据库；系统可能要求管理员确认。上次没读到："))
        XCTAssertFalse(utilities.contains("\"系统后台项读取诊断："), "the old literal is gone (the D229 comment keeps it in “”)")
        XCTAssertTrue(utilities.contains("if !store.startupCoverage.managedItemCoverageAvailable, let helper = helperAction, let title = helper.title {"))
        let access = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Views/Settings/SettingsAccess.swift"), encoding: .utf8)
        let section = try r2SourceDeclaration("var permissionSetupSection:", in: access)
        XCTAssertTrue(section.contains("fileOperationHelperRow"))
        let row = try r2SourceDeclaration("var fileOperationHelperRow:", in: access)
        for token in ["case .notRegistered?:", "case .requiresApproval?:", "confirmsFileOperationHelper = true",
                      "L10n.text(\"启用后台助手\", \"Enable Helper\")", "L10n.text(\"打开登录项\", \"Open Login Items\")"] {
            XCTAssertTrue(row.contains(token), token)
        }
    }
}
