import Foundation
import XCTest
import UninstallHandoffShared
@testable import StorageCleanerMac

/// D88 source guards: the Finder extension is a sandboxed Finder Sync appex,
/// embedded only in the installed Beta, signed before the outer app, and a
/// thin entry that opens the selection with its own host. No build registers
/// a public URL scheme.
final class FinderUninstallPackagingTests: XCTestCase {
    func testBuildScriptPackagesAndSignsSandboxedFinderSyncExtension() throws {
        let script = try MiniWindowLogicFixtures.source("script/build_and_run.sh")
        XCTAssertTrue(script.contains("FINDER_EXTENSION_NAME=\"StorageCleanerFinderExtension\""))
        XCTAssertTrue(script.contains("FINDER_EXTENSION_BUNDLE=\"$APP_PLUGINS/$FINDER_EXTENSION_NAME.appex\""))
        XCTAssertTrue(script.contains("<key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>"))
        XCTAssertTrue(script.contains("<key>CFBundlePackageType</key><string>XPC!</string>"))
        XCTAssertTrue(script.contains("<key>com.apple.security.app-sandbox</key><true/>"))
        let extensionSign = try XCTUnwrap(script.range(of: "--entitlements \"$FINDER_EXTENSION_ENTITLEMENTS\""))
        // The outer app carries the beta-only photo entitlement args (D89).
        let appSign = try XCTUnwrap(script.range(of: "codesign \"${sign_args[@]}\" ${main_entitlement_args[@]+\"${main_entitlement_args[@]}\"} --sign \"$SIGN_IDENTITY\" \"$APP_BUNDLE\""))
        XCTAssertLessThan(extensionSign.lowerBound, appSign.lowerBound, "nested code must be signed first")
        let verify = try MiniWindowLogicFixtures.section(script, from: "verify_sparkle_bundle() {", to: "\n}\n")
        XCTAssertTrue(verify.contains("NSExtension:NSExtensionPointIdentifier"))
        XCTAssertTrue(verify.contains("com.apple.security.app-sandbox"))
    }

    /// 修复轮 1 (P1-1): only `--beta --install` embeds the extension. `run`,
    /// `--bundle-only` (release identity) and a Beta assembled without
    /// installing carry no PlugIns, and the verifier rejects stray ones.
    func testOnlyTheInstalledBetaEmbedsTheExtension() throws {
        let script = try MiniWindowLogicFixtures.source("script/build_and_run.sh")
        XCTAssertTrue(script.contains("""
        EMBED_FINDER_EXTENSION=0
        if [ "$BETA_MODE" -eq 1 ] && [ "$BETA_INSTALL" -eq 1 ]; then
          EMBED_FINDER_EXTENSION=1
        fi
        """))
        let assembly = try MiniWindowLogicFixtures.section(script, from: "if [ \"$EMBED_FINDER_EXTENSION\" -eq 1 ]; then\n[ -x \"$BUILD_BIN_DIR/$FINDER_EXTENSION_NAME\" ]",
                                                           to: "\nfi\n")
        XCTAssertTrue(assembly.contains("mkdir -p \"$FINDER_EXTENSION_BUNDLE/Contents/MacOS\""))
        XCTAssertEqual(script.components(separatedBy: "mkdir -p \"$FINDER_EXTENSION_BUNDLE").count, 2, "assembled in one guarded place")
        let signing = try MiniWindowLogicFixtures.section(script, from: "# Nested code is signed before the outer bundle; the extension is sandboxed.\nif [ \"$EMBED_FINDER_EXTENSION\" -eq 1 ]; then",
                                                          to: "\nfi\n")
        XCTAssertTrue(signing.contains("-i \"$FINDER_EXTENSION_ID\""))
        let verify = try MiniWindowLogicFixtures.section(script, from: "verify_sparkle_bundle() {", to: "\n}\n")
        XCTAssertTrue(verify.contains("elif [ -e \"$APP_PLUGINS\" ]; then"))
    }

    /// 修复轮 1 (P1-2): no public URL scheme in any build.
    func testNoBuildRegistersAPublicURLScheme() throws {
        let script = try MiniWindowLogicFixtures.source("script/build_and_run.sh")
        XCTAssertFalse(script.contains("<key>CFBundleURLTypes</key>"))
        XCTAssertFalse(script.contains("CFBundleURLSchemes"))
        XCTAssertFalse(script.contains("UNINSTALL_URL_SCHEME"))
        let verify = try MiniWindowLogicFixtures.section(script, from: "verify_sparkle_bundle() {", to: "\n}\n")
        XCTAssertTrue(verify.contains("Print :CFBundleURLTypes"))
        XCTAssertTrue(verify.contains("unexpected CFBundleURLTypes"))
        let release = try MiniWindowLogicFixtures.source("script/make_release_dmg.sh")
        XCTAssertFalse(release.contains("CFBundleURLTypes"))
        let shared = try MiniWindowLogicFixtures.source("Sources/UninstallHandoffShared/FinderUninstallHandoff.swift")
        for forbidden in ["URLComponents", "static let scheme", "func parse(", "percentEncoded"] {
            XCTAssertFalse(shared.contains(forbidden), forbidden)
        }
    }

    func testPrincipalClassMatchesTheExtensionSource() throws {
        let script = try MiniWindowLogicFixtures.source("script/build_and_run.sh")
        let source = try MiniWindowLogicFixtures.source("Sources/FinderUninstallExtension/FinderUninstallExtension.swift")
        XCTAssertTrue(script.contains("FINDER_EXTENSION_PRINCIPAL_CLASS=\"StorageCleanerFinderUninstallExtension\""))
        XCTAssertTrue(source.contains("@objc(StorageCleanerFinderUninstallExtension)"))
        XCTAssertTrue(source.contains(": FIFinderSync"))
        let main = try MiniWindowLogicFixtures.source("Sources/FinderUninstallExtension/main.swift")
        XCTAssertTrue(main.contains("@_silgen_name(\"NSExtensionMain\")"))
    }

    /// 修复轮 1 (P1-1/P1-2): the menu and the handoff both require the
    /// installed Beta host; there is no fallback that opens anything else.
    func testExtensionOnlyHandsOffToItsInstalledHost() throws {
        let source = try MiniWindowLogicFixtures.source("Sources/FinderUninstallExtension/FinderUninstallExtension.swift")
        for forbidden in ["removeItem", "trashItem", "moveItem", "enumerator", "contentsOfDirectory", "Process(",
                          "recycle", "attributesOfItem", "requestUninstall",
                          "NSWorkspace.shared.open(url)", "open(url)", "URLComponents", "scheme", "makeURL"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertTrue(source.contains("FinderUninstallHandoff.hostApplication(forExtensionAt: Bundle.main.bundleURL)"))
        XCTAssertTrue(source.contains("guard menuKind == .contextualMenuForItems, host != nil,"))
        XCTAssertTrue(source.contains("guard let host,"))
        XCTAssertTrue(source.contains("NSWorkspace.shared.open(applications, withApplicationAt: host, configuration: configuration)"))
        XCTAssertEqual(source.components(separatedBy: "NSWorkspace.shared.open(").count, 2, "exactly one open call")
    }

    /// 实机验收 2026-10-13: a sandboxed extension can only hand .app bundles
    /// over as documents, which Launch Services refuses (-10820) unless the
    /// host claims the type; only the extension-carrying Beta claims it, at
    /// Alternate rank, once the plist is complete.
    func testInstalledBetaClaimsApplicationBundlesOnlyWithTheExtension() throws {
        let script = try MiniWindowLogicFixtures.source("script/build_and_run.sh")
        let closed = try XCTUnwrap(script.range(of: "cat >>\"$INFO_PLIST\" <<PLIST\n</dict>\n</plist>\nPLIST"))
        let claim = try XCTUnwrap(script.range(of: "if [ \"$EMBED_FINDER_EXTENSION\" -eq 1 ]; then\n  plutil -insert CFBundleDocumentTypes -json"))
        XCTAssertLessThan(closed.lowerBound, claim.lowerBound)
        XCTAssertEqual(script.components(separatedBy: "CFBundleDocumentTypes -json").count, 2, "claimed in one guarded place")
        XCTAssertTrue(script.contains("\"LSHandlerRank\":\"Alternate\",\"LSItemContentTypes\":[\"com.apple.application-bundle\"]}]"))
        let verify = try MiniWindowLogicFixtures.section(script, from: "verify_sparkle_bundle() {", to: "\n}\n")
        XCTAssertTrue(verify.contains("Print :CFBundleDocumentTypes:0:LSItemContentTypes:0"))
        XCTAssertTrue(verify.contains("unexpected CFBundleDocumentTypes in a bundle without the Finder extension"))
        let release = try MiniWindowLogicFixtures.source("script/make_release_dmg.sh")
        XCTAssertFalse(release.contains("CFBundleDocumentTypes"))
    }

    /// 实机验收 2026-10-13: Finder calls menu(for:) on an XPC queue, so the
    /// menu must not assert main-actor isolation on the calling thread.
    func testMenuIsBuiltOnTheMainQueueNotTheCallingThread() throws {
        let source = try MiniWindowLogicFixtures.source("Sources/FinderUninstallExtension/FinderUninstallExtension.swift")
        let menuStart = try XCTUnwrap(source.range(of: "override func menu(for menuKind: FIMenuKind) -> NSMenu? {"))
        let hop = try XCTUnwrap(source.range(of: "Self.onMainQueue {", range: menuStart.upperBound..<source.endIndex))
        let isolated = try XCTUnwrap(source.range(of: "MainActor.assumeIsolated {", range: menuStart.upperBound..<source.endIndex))
        XCTAssertLessThan(hop.lowerBound, isolated.lowerBound)
        XCTAssertTrue(source.contains("DispatchQueue.main.sync(execute: work)"))
        XCTAssertTrue(source.contains("if Thread.isMainThread {"))
    }

    /// 修复轮 1 (P1-3): open-documents in the delegate, queued until the main
    /// window attaches, and handled by the existing window.
    func testMainApplicationRoutesOpenDocumentsIntoTheExistingReview() throws {
        let app = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift")
        XCTAssertTrue(app.contains("func application(_ application: NSApplication, open urls: [URL]) {\n        ExternalUninstallRequestCenter.shared.receive(openedURLs: urls)"))
        XCTAssertFalse(app.contains("kAEGetURL"))
        XCTAssertFalse(app.contains("setEventHandler"))
        XCTAssertTrue(app.contains(".modifier(ExternalUninstallRequestBridge(store: store, center: .shared))"))
        let center = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Services/ExternalUninstallRequests.swift")
        XCTAssertTrue(center.contains("host.requestUninstall(app)"))
        XCTAssertTrue(center.contains(".handlesExternalEvents(preferring: [\"*\"], allowing: [\"*\"])"))
        XCTAssertTrue(center.contains(".onAppear { center.attach(store) }"))
        // 实机验收 2026-10-13: the event's own window is the main window; asking
        // for the "primary" one as well opened a second main window.
        let window = try MiniWindowLogicFixtures.section(center, from: "var showMainWindow: @MainActor () -> Void = {", to: "\n    }\n")
        XCTAssertFalse(window.contains("requestMainWindow"))
        XCTAssertFalse(window.contains("openWindow"))
        XCTAssertFalse(center.contains("MainWindowReopenCoordinator"))
        for forbidden in ["confirmUninstall", "uninstallSelectedPaths", "AppUninstallService.execute", "moveToTrash",
                          "errorMessage = "] {
            XCTAssertFalse(center.contains(forbidden), forbidden)
        }
    }
}
