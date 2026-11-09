import AgentGatewayCore
import AgentShared
import XCTest

/// 2.0.0 发布前发现：正式打包脚本没有跟上测试版构建脚本，正式包缺文件操作助手、
/// 更新授权助手、BuildInfo、应用管理用途说明，且主程序链接的 SDK 版本退回最低系统版本。
/// 这些组件由 build_and_run.sh 对所有构建无条件嵌入，正式包必须同样具备；
/// 访达扩展（D88）与照片图库 entitlement（D89）仍只属于测试版。
final class ReleasePackagingParityTests: XCTestCase {
    func testReleaseEmbedsEveryComponentTheRunScriptAlwaysEmbeds() throws {
        let run = try MiniWindowLogicFixtures.source("script/build_and_run.sh")
        let release = try MiniWindowLogicFixtures.source("script/make_release_dmg.sh")

        // Unconditional in build_and_run.sh …
        XCTAssertTrue(run.contains("FILE_HELPER_NAME=\"StorageCleanerFileOperationHelper\""))
        XCTAssertTrue(run.contains("\"$BUILD_BIN_DIR/StorageCleanerUpdateAskpass\""))
        XCTAssertTrue(run.contains("<key>NSAppBundlesUsageDescription</key>"))
        XCTAssertTrue(run.contains("cat >\"$BUILD_INFO_PLIST\""))

        // … and therefore required in the production package.
        XCTAssertTrue(release.contains("FILE_HELPER_NAME=\"StorageCleanerFileOperationHelper\""))
        XCTAssertTrue(release.contains("FILE_HELPER_LABEL=\"$BUNDLE_ID.FileOperationHelper\""))
        XCTAssertTrue(release.contains("--product \"$FILE_HELPER_NAME\" \\\n  -Xlinker -sectcreate"))
        XCTAssertTrue(release.contains("/usr/bin/ditto --norsrc \"$FILE_HELPER_BINARY\" \"$APP_RESOURCES/$FILE_HELPER_NAME\""))
        XCTAssertTrue(release.contains("/usr/bin/ditto --norsrc \"$UPDATE_ASKPASS_BINARY\" \"$APP_RESOURCES/$UPDATE_ASKPASS_NAME\""))
        XCTAssertTrue(release.contains("cat >\"$APP_LAUNCH_DAEMONS/$FILE_HELPER_PLIST\""))
        XCTAssertTrue(release.contains("-i \"$FILE_HELPER_LABEL\""))
        XCTAssertTrue(release.contains("-i \"$BUNDLE_ID.update-askpass\""))
        XCTAssertTrue(release.contains("<key>NSAppBundlesUsageDescription</key>"))
        XCTAssertTrue(release.contains("cat >\"$APP_RESOURCES/BuildInfo.plist\""))
    }

    /// D260: the AI assistant bridge ships in every bundle at the path the
    /// gateway checks, signed under its own identifier before the outer bundle.
    func testBothPackagesEmbedSignAndVerifyTheAgentBridge() throws {
        let run = try MiniWindowLogicFixtures.source("script/build_and_run.sh")
        let release = try MiniWindowLogicFixtures.source("script/make_release_dmg.sh")
        for (name, script) in [("build_and_run.sh", run), ("make_release_dmg.sh", release)] {
            XCTAssertTrue(script.contains("AGENT_BRIDGE_PRODUCT=\"StorageCleanerAgentBridge\""), name)
            XCTAssertTrue(script.contains("AGENT_BRIDGE_RELATIVE_PATH=\"\(AgentGatewayPolicy.bridgeRelativePath)\""), name)
            XCTAssertTrue(script.contains("-i \"$BUNDLE_ID\(AgentBridgePeerPolicy.identifierSuffix)\""), name)
            XCTAssertTrue(script.contains("Identifier=$BUNDLE_ID\(AgentBridgePeerPolicy.identifierSuffix)"), name)
            XCTAssertTrue(script.contains("verify_executable_compatibility \"") && script.contains("AGENT_BRIDGE"), name)
        }
        XCTAssertTrue(release.contains("/usr/bin/ditto --norsrc \"$AGENT_BRIDGE_BINARY\" \"$APP_BUNDLE/$AGENT_BRIDGE_RELATIVE_PATH\""))
        XCTAssertTrue(run.contains("/usr/bin/ditto --norsrc \"$BUILD_BIN_DIR/$AGENT_BRIDGE_PRODUCT\" \"$APP_AGENT_BRIDGE\""))
        // Nested code is signed first: the outer signature seals it.
        let runBridge = try XCTUnwrap(run.range(of: "-i \"$BUNDLE_ID.agent-bridge\""))
        let runOuter = try XCTUnwrap(run.range(of: "--sign \"$SIGN_IDENTITY\" \"$APP_BUNDLE\" >/dev/null"))
        XCTAssertLessThan(runBridge.lowerBound, runOuter.lowerBound)
        let signing = try MiniWindowLogicFixtures.section(release, from: "clean_attrs \"$app_path\"\n", to: "codesign --verify --deep --strict --verbose=4 \"$app_path\"")
        let releaseBridge = try XCTUnwrap(signing.range(of: "-i \"$BUNDLE_ID.agent-bridge\""))
        let releaseOuter = try XCTUnwrap(signing.range(of: "--sign \"$SIGN_IDENTITY\" \"$app_path\" >/dev/null"))
        XCTAssertLessThan(releaseBridge.lowerBound, releaseOuter.lowerBound)
        XCTAssertTrue(signing.contains("codesign --verify --strict \"$app_path/$AGENT_BRIDGE_RELATIVE_PATH\""))
        // The Beta's bridge carries the same Team ID as the app (D263).
        let verify = try MiniWindowLogicFixtures.section(run, from: "verify_sparkle_bundle() {", to: "\n}\n")
        XCTAssertTrue(verify.contains("[ \"$app_team\" = \"$bridge_team\" ]"))
        let installed = try MiniWindowLogicFixtures.section(run, from: "verify_beta_bundle_at() {", to: "\n}\n")
        XCTAssertTrue(installed.contains("codesign --verify --strict --verbose=4 \"$bundle/$AGENT_BRIDGE_RELATIVE_PATH\""))
    }

    func testReleaseLinksAgainstTheActualSDKLikeTheRunScript() throws {
        let release = try MiniWindowLogicFixtures.source("script/make_release_dmg.sh")
        let linkArgs = "-Xlinker -platform_version\n  -Xlinker macos\n  -Xlinker \"$MIN_SYSTEM_VERSION\"\n  -Xlinker \"$BUILD_SDK_VERSION\""
        XCTAssertTrue(release.contains(linkArgs))
        // Every swift build in the release script goes through the shared argument list.
        let builds = release.components(separatedBy: "\"$SWIFT_TOOL\" build ").dropFirst()
        XCTAssertFalse(builds.isEmpty)
        for build in builds {
            XCTAssertTrue(build.hasPrefix("\"${swift_build_args[@]}\""), String(build.prefix(80)))
        }
    }

    func testReleaseVerifiesTheNewComponentsAndKeepsBetaOnlyPiecesOut() throws {
        let release = try MiniWindowLogicFixtures.source("script/make_release_dmg.sh")
        let verify = try MiniWindowLogicFixtures.section(release, from: "verify_app_metadata() {", to: "\n}\n")
        XCTAssertTrue(verify.contains("missing file-operation helper, its launch daemon plist, or update askpass"))
        XCTAssertTrue(verify.contains("assert_plist_value \"$file_helper_plist\" Label \"$FILE_HELPER_LABEL\""))
        XCTAssertTrue(verify.contains("missing NSAppBundlesUsageDescription"))
        XCTAssertTrue(verify.contains("BuildInfo.plist\" build \"$APP_BUILD\""))
        XCTAssertTrue(verify.contains("must not embed extensions"))
        XCTAssertTrue(verify.contains("must not carry the photo-library entitlement"))
        XCTAssertFalse(release.contains("--entitlements \"$ROOT_DIR"), "no signing entitlements (D89)")
        XCTAssertFalse(release.contains("FINDER_EXTENSION"))
        XCTAssertFalse(release.contains("plutil -insert NSPhotoLibraryUsageDescription"))
    }
}
