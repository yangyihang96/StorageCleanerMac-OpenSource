import XCTest
@testable import StorageCleanerMac

/// D204 (report §4 item 19, decided by the user on 10-24): the module
/// landings list their categories by name only, as CleanMyMac's do
/// (`1比1对照-20261023/cmm/01`–`08`); what a line covers is for VoiceOver.
final class LandingNamesOnlyTests: XCTestCase {
    func testTheCloudLandingListsNamesAndSaysWhenICloudIsOff() {
        let provider = CloudDriveScanner.Provider(folderName: "Dropbox", path: "/fixture/dropbox")
        let cases: [(Bool, [CloudDriveScanner.Provider])] = [(true, []), (false, []), (true, [provider]), (false, [provider])]
        for (available, providers) in cases {
            let bullets = CloudCleanupPresentation.landingBullets(iCloudDriveAvailable: available, providers: providers)
            XCTAssertTrue(bullets.allSatisfy { $0.detail == nil }, "nothing under the names")
            XCTAssertTrue(bullets.allSatisfy { $0.hint?.isEmpty == false }, "each line still explains itself to VoiceOver")
        }
        XCTAssertNil(CloudCleanupPresentation.landingStatus(iCloudDriveAvailable: true))
        XCTAssertEqual(CloudCleanupPresentation.landingStatus(iCloudDriveAvailable: false),
                       L10n.text("这台 Mac 没有启用 iCloud 云盘", "iCloud Drive is off on this Mac"),
                       "the iCloud line's old second line stays on the page")
    }

    func testNamesKeepCleanMyMacsPitch() {
        XCTAssertEqual(CareStudioMetrics.bulletSize, 17)
        XCTAssertEqual(CareStudioMetrics.bulletIconSide + CareStudioMetrics.bulletNameSpacing, 52,
                       "a line every 52 pt, as on cmm/01–05")
    }
}
