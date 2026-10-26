import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MailLibraryAttachmentPresentationTests: XCTestCase {
    func testGroupsBothMailRulesTogetherAndNamesMailboxesInBothLanguages() throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            let chinese = language == .zhHans
            for rule in [CleanupCoverageCatalog.mailLibraryAttachmentFoldersRule, CleanupCoverageCatalog.mailDownloadedAttachmentsRule] {
                XCTAssertEqual(CareJunkGroup.group(categoryID: rule.categoryID, candidates: []), .mailAttachments)
                XCTAssertEqual(CareJunkGroup.group(ruleID: rule.id), .mailAttachments)
            }
            XCTAssertEqual(CareJunkGroup.mailAttachments.title, chinese ? "邮件附件" : "Mail Attachments")
            let inbox = "/H/Library/Mail/V10/ACCOUNT/INBOX.mbox/U/Data/1/Attachments"
            let nested = "/H/Library/Mail/V10/ACCOUNT/Archive.mbox/2025.mbox/U/Data/1/Attachments"
            XCTAssertEqual(MailAttachmentPresentation.mailboxName(for: URL(fileURLWithPath: inbox)), chinese ? "收件箱" : "Inbox")
            XCTAssertEqual(MailAttachmentPresentation.mailboxName(for: URL(fileURLWithPath: nested)), chinese ? "归档 / 2025" : "Archive / 2025")
            XCTAssertEqual(MailAttachmentPresentation.mailboxName(for: URL(fileURLWithPath: "/H/Library/Mail/V10/account/Projects%20A.mbox/Attachments")), "Projects A")
            XCTAssertEqual(MailAttachmentPresentation.mailboxName(for: URL(fileURLWithPath: "/H/Library/Mail/V10/account/Data/1/Attachments")), "account/Data/1/Attachments")
            let row = RescanFixtureRows.candidate("mail.library-attachment-folders", inbox,
                sessionID: ScanSessionID(), inode: 183, bytes: 1_200_000)
            XCTAssertEqual(CareStudioCandidateRow.title(for: row), chinese ? "收件箱" : "Inbox")
        }
    }

    func testTitleReasonAndImpactExplainTrashServerDownloadAndLocalRestoration() throws {
        let rule = CleanupCoverageCatalog.mailLibraryAttachmentFoldersRule
        let impact = try XCTUnwrap(rule.maintenance?.impact)
        let englishImpact = try XCTUnwrap(CleanupImpactText.englishByChinese[impact])
        for term in ["废纸篓", "放回", "IMAP", "POP", "我的 Mac 上"] { XCTAssertTrue(impact.contains(term), term) }
        for term in ["Trash", "put back", "IMAP", "POP", "On My Mac"] { XCTAssertTrue(englishImpact.contains(term), term) }
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            XCTAssertEqual(CleanupRuleCopy.text(for: rule.titleKey), language == .zhHans ? "邮件附件" : "Mail Attachments")
            XCTAssertEqual(CleanupRuleCopy.title(for: rule), language == .zhHans ? "Apple Mail · 邮件附件" : "Apple Mail · Mail Attachments")
            let reason = CleanupRuleCopy.text(for: rule.reasonKey)
            for term in ["IMAP", "POP", language == .zhHans ? "废纸篓" : "Trash",
                         language == .zhHans ? "放回" : "put", language == .zhHans ? "我的 Mac 上" : "On My Mac"] {
                XCTAssertTrue(reason.contains(term), term)
            }
        }
    }
}
