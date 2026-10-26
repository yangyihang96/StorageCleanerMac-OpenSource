import Foundation
import XCTest
@testable import StorageCleanerMac

/// D101 G9: the uninstall page names the developer's own uninstaller when one
/// sits beside the app or inside it with the app's Team ID, and opens it only
/// when the user clicks. Fixtures are plain folders; signatures and the opener
/// are fakes, so nothing is launched.
final class VendorUninstallerTests: XCTestCase {
    private var root: URL!
    private var applications: URL!

    override func setUpWithError() throws {
        let base = TestFileSystem.uniqueRoot("VendorUninstaller")
        TestFileSystem.registerCleanup(of: base, for: self)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Applications"),
                                                withIntermediateDirectories: true)
        // Directory listings report /private/var/...; `paths(_:)` compares
        // in the lexical spelling, /var/....
        root = base
        applications = root.appendingPathComponent("Applications", isDirectory: true)
    }

    func testAnUninstallerBesideTheAppWithTheSameTeamIsOffered() async throws {
        let app = try makeApp("Vendor Suite/Acrobat.app")
        let uninstaller = try makeApp("Vendor Suite/Acrobat Uninstaller.app")
        _ = try makeApp("Vendor Suite/Acrobat Helper.app")
        let signatures = FakeSignatures([app: "TEAM1", uninstaller: "TEAM1"])
        let opener = FakeOpener()

        let found = await service(signatures, opener).uninstaller(forApplicationAt: app)
        XCTAssertEqual(paths(found.map { [$0.url] } ?? []), [uninstaller.path])
        XCTAssertEqual(found?.teamIdentifier, "TEAM1")
        XCTAssertEqual(found?.name, "Acrobat Uninstaller")
        let opened = await opener.opened
        XCTAssertTrue(opened.isEmpty, "Finding the uninstaller must not open it")
    }

    func testAnUninstallerFromAnotherDeveloperIsNotOffered() async throws {
        let app = try makeApp("Other Suite/Reader.app")
        let impostor = try makeApp("Other Suite/Reader Uninstaller.app")
        let opener = FakeOpener()
        var found = await service(FakeSignatures([app: "TEAM1", impostor: "TEAM2"]), opener)
            .uninstaller(forApplicationAt: app)
        XCTAssertNil(found)
        // The same Team ID on a signature that does not validate is no proof.
        found = await service(FakeSignatures([app: "TEAM1", impostor: "TEAM1"], invalid: [impostor]), opener)
            .uninstaller(forApplicationAt: app)
        XCTAssertNil(found)
        // An app without a trusted Team ID has nothing to match.
        found = await service(FakeSignatures([app: nil, impostor: nil]), opener).uninstaller(forApplicationAt: app)
        XCTAssertNil(found)
        found = await service(FakeSignatures([impostor: "TEAM1"]), opener).uninstaller(forApplicationAt: app)
        XCTAssertNil(found)
        let opened = await opener.opened
        XCTAssertTrue(opened.isEmpty)
    }

    func testWithoutAnUninstallerNoSignatureIsRead() async throws {
        let app = try makeApp("Plain/Tool.app")
        _ = try makeApp("Plain/Tool Helper.app")
        try Data().write(to: root.appendingPathComponent("Applications/Plain/Uninstall Tool.txt"))
        let signatures = FakeSignatures([app: "TEAM1"])
        let found = await service(signatures, FakeOpener()).uninstaller(forApplicationAt: app)
        XCTAssertNil(found)
        let inspected = await signatures.inspected
        XCTAssertTrue(inspected.isEmpty, "\(inspected)")
    }

    func testUninstallersInsideTheBundleAreFoundWithinTheDepthLimit() throws {
        let app = try makeApp("Bundled.app")
        let shallow = try makeApp("Bundled.app/Contents/Resources/Bundled Uninstaller.app")
        let level3 = try makeApp("Bundled.app/Contents/SharedSupport/Tools/卸载助手.app")
        _ = try makeApp("Bundled.app/Contents/A/B/C/Deep Uninstaller.app")
        // Not looked into: another app nested in the bundle.
        _ = try makeApp("Bundled.app/Contents/Helpers/Agent.app/Contents/Resources/Agent Uninstaller.app")
        XCTAssertEqual(paths(VendorUninstallerLocator.candidates(for: app, sharedFolders: [applications.path])),
                       [shallow.path, level3.path])
    }

    func testInASharedApplicationsFolderTheUninstallerMustNameTheApp() throws {
        let app = try makeApp("Citrix Workspace.app")
        let own = try makeApp("Uninstall Citrix Workspace.app")
        _ = try makeApp("Uninstall Other Product.app")
        XCTAssertEqual(paths(VendorUninstallerLocator.candidates(for: app, sharedFolders: [applications.path])), [own.path])
        // In the app's own folder any uninstaller name counts.
        let suiteApp = try makeApp("Suite/Editor.app")
        let suiteUninstaller = try makeApp("Suite/Remove Suite Uninstaller.app")
        XCTAssertEqual(paths(VendorUninstallerLocator.candidates(for: suiteApp, sharedFolders: [applications.path])),
                       [suiteUninstaller.path])
        XCTAssertTrue(VendorUninstallerLocator.isUninstallerName("卸载工具"))
        XCTAssertTrue(VendorUninstallerLocator.isUninstallerName("ACROBAT UNINSTALLER"))
        XCTAssertFalse(VendorUninstallerLocator.isUninstallerName("Installer"))
    }

    func testLinksAreNotFollowed() throws {
        let target = try makeApp("Elsewhere/Real Uninstaller.app")
        let app = try makeApp("Linked/Linked.app")
        try FileManager.default.createSymbolicLink(
            at: applications.appendingPathComponent("Linked/Linked Uninstaller.app"), withDestinationURL: target)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("Contents/Resources"), withDestinationURL: target.deletingLastPathComponent())
        XCTAssertEqual(VendorUninstallerLocator.candidates(for: app, sharedFolders: [applications.path]), [])
    }

    func testOpeningChecksTheSignatureAgainAndOpensOnce() async throws {
        let app = try makeApp("Vendor/Tool.app")
        let uninstallerURL = try makeApp("Vendor/Tool Uninstaller.app")
        let signatures = FakeSignatures([app: "TEAM1", uninstallerURL: "TEAM1"])
        let opener = FakeOpener()
        let vendor = service(signatures, opener)
        let found = await vendor.uninstaller(forApplicationAt: app)
        let uninstaller = try XCTUnwrap(found)

        let first = await vendor.open(uninstaller)
        XCTAssertEqual(first, .opened)
        var opened = await opener.opened
        XCTAssertEqual(paths(opened), [uninstallerURL.path])

        await signatures.set(uninstallerURL, team: "TEAM2")
        let changed = await vendor.open(uninstaller)
        XCTAssertEqual(changed, .changed)
        await signatures.set(uninstallerURL, team: "TEAM1")
        try FileManager.default.removeItem(at: uninstallerURL)
        try FileManager.default.createSymbolicLink(at: uninstallerURL,
                                                   withDestinationURL: try makeApp("Other/Tool Uninstaller.app"))
        let linked = await vendor.open(uninstaller)
        XCTAssertEqual(linked, .changed)
        opened = await opener.opened
        XCTAssertEqual(paths(opened), [uninstallerURL.path], "Nothing else is opened")

        let failing = FakeOpener(fails: true)
        try FileManager.default.removeItem(at: uninstallerURL)
        _ = try makeApp("Vendor/Tool Uninstaller.app")
        let failed = await service(signatures, failing).open(uninstaller)
        XCTAssertEqual(failed, .failed)
    }

    @MainActor
    func testTheControllerOpensOnlyWhenAsked() async throws {
        let app = try makeApp("Vendor/Tool.app")
        let uninstallerURL = try makeApp("Vendor/Tool Uninstaller.app")
        let signatures = FakeSignatures([app: "TEAM1", uninstallerURL: "TEAM1"])
        let opener = FakeOpener()
        let controller = VendorUninstallerController(service: service(signatures, opener))

        await controller.load(applicationPath: app.path)
        XCTAssertEqual(paths(controller.uninstaller.map { [$0.url] } ?? []), [uninstallerURL.path])
        XCTAssertNil(controller.message)
        var opened = await opener.opened
        XCTAssertTrue(opened.isEmpty)

        await controller.open()
        opened = await opener.opened
        XCTAssertEqual(paths(opened), [uninstallerURL.path])
        XCTAssertTrue(controller.message?.contains("Tool Uninstaller") == true)
        XCTAssertFalse(controller.isOpening)

        await signatures.set(uninstallerURL, team: "TEAM2")
        await controller.open()
        XCTAssertNil(controller.uninstaller, "A changed uninstaller is no longer offered")
        opened = await opener.opened
        XCTAssertEqual(opened.count, 1)

        await controller.load(applicationPath: nil)
        XCTAssertNil(controller.uninstaller)
        XCTAssertNil(controller.message)
    }

    /// Opening happens in one place, from the button; the page's controller
    /// never reaches the uninstall flow.
    func testOnlyTheButtonOpensTheUninstaller() throws {
        let service = "Sources/StorageCleanerMac/Services/VendorUninstallerService.swift"
        let view = "Sources/StorageCleanerMac/Views/UninstallPreviewSheet.swift"
        let compact = try SwiftSourceScanning.compactSourceCode()
        XCTAssertEqual(compact.filter { $0.value.contains("VendorUninstallerController(") }.keys.sorted(), [view])
        XCTAssertEqual(compact.filter { $0.value.contains("vendorUninstaller.open()") }.keys.sorted(), [view])
        let viewText = SwiftSourceScanning.compactKeepingLiterals(try XCTUnwrap(SwiftSourceScanning.sources()[view]))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "vendorUninstaller.open()", in: viewText), 1)
        XCTAssertTrue(viewText.contains(#"Button(L10n.text("打开卸载程序","Open Uninstaller")){Task{awaitvendorUninstaller.open()}}"#))

        let code = try XCTUnwrap(SwiftSourceScanning.sourceCode()[service])
        let serviceCode = SwiftSourceScanning.compact(code)
        // The NSWorkspace call in the default value, and the one call of it.
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "openApplication(", in: serviceCode), 2)
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "tryawaitopenApplication(uninstaller.url)", in: serviceCode), 1)
        XCTAssertEqual(compact.filter { $0.value.contains("VendorUninstallerService(") }.keys.sorted(), [service])
        let open = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "func open(_ uninstaller: VendorUninstaller)", in: code))
        XCTAssertTrue(open.hasPrefix(
            "guardVendorUninstallerLocator.isPlainApplicationFolder(uninstaller.url),awaittrustedTeam(at:uninstaller.url)==uninstaller.teamIdentifierelse{return.changed}"
        ), open)
        let controller = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "final class VendorUninstallerController", in: code))
        for word in ["ScanStore", "Uninstall(", "recycle", "removeItem", "trashItem"] {
            XCTAssertFalse(controller.contains(word), word)
        }
    }

    // MARK: Helpers

    private func paths(_ urls: [URL]) -> [String] {
        urls.map { PathSafety.lexicalPath($0.path) }
    }

    private func service(_ signatures: FakeSignatures, _ opener: FakeOpener) -> VendorUninstallerService {
        VendorUninstallerService(signatures: signatures, openApplication: { try await opener.open($0) },
                                 homeDirectory: root, sharedFolders: [applications.path])
    }

    @discardableResult
    private func makeApp(_ relative: String) throws -> URL {
        let app = applications.appendingPathComponent(relative, isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/" + app.deletingPathExtension().lastPathComponent)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/false\n".utf8).write(to: executable)
        return URL(fileURLWithPath: PathSafety.lexicalPath(app.path), isDirectory: true)
    }
}

/// Team IDs by path; a missing path or nil is an unsigned or untrusted app.
private actor FakeSignatures: ApplicationCodeSignatureInspecting {
    private var teams: [String: String?]
    private let invalid: Set<String>
    private(set) var inspected: [String] = []

    init(_ teams: [URL: String?], invalid: Set<URL> = []) {
        self.teams = Dictionary(uniqueKeysWithValues: teams.map { (PathSafety.lexicalPath($0.key.path), $0.value) })
        self.invalid = Set(invalid.map { PathSafety.lexicalPath($0.path) })
    }

    func set(_ url: URL, team: String?) {
        teams[PathSafety.lexicalPath(url.path)] = .some(team)
    }

    func inspectSignature(at applicationURL: URL) -> ApplicationCodeSignatureMetadata {
        let path = PathSafety.lexicalPath(applicationURL.path)
        inspected.append(path)
        let team = teams[path] ?? nil
        return ApplicationCodeSignatureMetadata(signingTeamIdentifier: team, codeSigningIdentifier: nil,
                                                isValid: team != nil && !invalid.contains(path))
    }
}

/// Records what would have been opened; nothing is launched.
private actor FakeOpener {
    private let fails: Bool
    private(set) var opened: [URL] = []

    init(fails: Bool = false) { self.fails = fails }

    func open(_ url: URL) throws {
        guard !fails else { throw CocoaError(.fileReadUnknown) }
        opened.append(URL(fileURLWithPath: PathSafety.lexicalPath(url.path), isDirectory: true))
    }
}
