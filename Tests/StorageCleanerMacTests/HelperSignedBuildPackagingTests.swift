import Foundation
import XCTest
@testable import StorageCleanerMac

final class HelperSignedBuildPackagingTests: XCTestCase {
    func testEveryPackagingPathEmbedsHelperVersionBeforeCopyAndSigning() throws {
        for path in ["script/build_and_run.sh", "script/make_release_dmg.sh"] {
            let source = try MiniWindowLogicFixtures.source(path)
            let embed = try XCTUnwrap(source.range(of: "-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist"))
            let copy = try XCTUnwrap(source.range(of: "/usr/bin/ditto --norsrc \"$FAN_HELPER_BINARY\""))
            XCTAssertLessThan(embed.lowerBound, copy.lowerBound, path)
            XCTAssertTrue(source.contains("--product \"$FAN_HELPER_NAME\""), path)
            XCTAssertTrue(source.contains("HELPER_SIGNED_INFO=\"$SWIFT_BUILD_DIR/helper-signed-info-$APP_BUILD.plist\""),
                          "The version changes the linker command, even when helper sources are cached")
            XCTAssertTrue(source.contains("\"$APP_BUILD\" \"$FAN_HELPER_LABEL\" \"$FAN_HELPER_NAME\""), path)
        }
        let source = try MiniWindowLogicFixtures.source("Sources/FanControlHelper/main.swift")
        let check = try MiniWindowLogicFixtures.section(source, from: "static func validatedReplacement", to: "static func clientProcess")
        XCTAssertFalse(check.contains("Info.plist\""))
        XCTAssertFalse(check.contains("BuildInfo.plist\""))
        XCTAssertTrue(check.contains("replacementBuild: replacement.signedBuild"))
    }

    func testAllReconnectSurfacesShowAndDisableDuringCooldown() throws {
        let settings = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("Button(fanControl.helperReconnectTitle)"))
        XCTAssertTrue(settings.contains("fanControl.helperReconnectWaitSeconds > 0"))
        let palette = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift")
        XCTAssertEqual(palette.components(separatedBy: "reconnectWaitSeconds: fanControl.helperReconnectWaitSeconds").count - 1, 2)
        XCTAssertTrue(palette.contains("isReconnectAction && reconnectWaitSeconds > 0"))
        XCTAssertTrue(palette.contains("等待 \\(reconnectWaitSeconds) 秒"))
        let summary = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift")
        XCTAssertTrue(summary.contains("compactHelperActionIsReconnect && fanControl.helperReconnectWaitSeconds > 0"))
        XCTAssertTrue(summary.contains("case .enabled, .connectionInterrupted, .signatureRejected: fanControl.helperReconnectTitle"))
    }
}
