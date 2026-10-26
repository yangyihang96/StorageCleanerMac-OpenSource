import Darwin
import FileOperationShared
import XCTest
@testable import StorageCleanerMac

/// D101 G4-2: protected locations in three layers. Layer 1 is what no flow
/// may touch, read by File Analysis, uninstall and the cleanup rules alike
/// (the scanner's part is in CleanupJunkActionableTests); layer 2 stays in
/// the rule check; layer 3 is the file flags. No protection that existed
/// before is lost, and each flow's own legitimate items still pass.
final class ProtectedLocationLayersTests: XCTestCase {
    /// File Analysis spelled these lists out itself before G4-2; the layers
    /// rebuild them exactly.
    func testFileAnalysisKeepsEveryLocationItProtectedBefore() {
        XCTAssertEqual(FileAnalysisTrashPolicy.protectedLibraryFolderNames, [
            "Keychains", "Mail", "Messages", "Safari", "Accounts", "Calendars", "Cookies", "HomeKit", "Passes",
            "Autosave Information", "LaunchAgents", "Preferences", "Mobile Documents", "CloudStorage", "Biome",
            "IdentityServices", "Sharing", "Suggestions", "Metadata", "Daemon Containers", "Reminders", "Shortcuts",
        ])
        XCTAssertEqual(FileAnalysisTrashPolicy.sharedLibraryFolderNames,
                       ["Containers", "Group Containers", "Application Support"])
        XCTAssertEqual(FileAnalysisTrashPolicy.protectedSharedEntryNames, [
            "AddressBook", "CallHistoryDB", "Knowledge", "FileProvider", "CloudDocs", "iCloud",
            "CallHistoryTransactions", "DifferentialPrivacy", "Dock",
            "group.is.workflow.shortcuts", "group.is.workflow.my.app",
        ])
        XCTAssertEqual(FileAnalysisTrashPolicy.credentialPaths, [
            ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config/gh", ".config/gcloud", ".netrc",
            ".git-credentials", ".npmrc", ".pypirc", ".pgpass", ".cargo/credentials", ".cargo/credentials.toml",
            ".config/op", ".password-store", ".terraform.d/credentials.tfrc.json",
        ])
        XCTAssertEqual(FileAnalysisTrashPolicy.credentialFilePaths, [
            ".netrc", ".git-credentials", ".npmrc", ".pypirc", ".pgpass", ".cargo/credentials",
            ".cargo/credentials.toml", ".terraform.d/credentials.tfrc.json",
        ])
        XCTAssertEqual(FileAnalysisTrashPolicy.integrationDataPrefix, "Library/Caches/StorageCleanerIntegration-")
        XCTAssertEqual(FileAnalysisTrashPolicy.appDataRelativePaths, ProtectedLocations.appDataRelativePaths)
        // Only File Analysis keeps these whole: uninstall removes an app's own preferences.
        XCTAssertEqual(FileAnalysisTrashPolicy.protectedLibraryFolderNames.subtracting(
            ProtectedLocations.libraryFolderNames.union(ProtectedLocations.cloudLibraryFolderNames)
        ), ["Cookies", "LaunchAgents", "Preferences"])
    }

    /// File Analysis gives each layer-1 location, and what is inside it, the
    /// same reason as before.
    func testFileAnalysisBlocksEachLocationNoFlowMayTouch() {
        let home = "/Users/g4-2-fixture"
        let policy = FileAnalysisTrashPolicy(
            rootPath: home, targetKind: .homeDirectory, homePath: home,
            appDataPath: home + "/Library/Application Support/Fixture Data", excludedPaths: [])
        for (relative, block) in Self.layerOneSamples {
            for path in ["\(home)/\(relative)", "\(home)/\(relative)/inside"] {
                XCTAssertEqual(policy.block(path: path, name: (path as NSString).lastPathComponent, kind: "folder",
                                            isDirectory: true, isEstimated: false), block, path)
            }
        }
        // What only File Analysis keeps whole is still kept.
        for relative in ["Library/Preferences", "Library/Cookies/x", "Library/Containers/com.apple.mail"] {
            XCTAssertEqual(policy.block(path: "\(home)/\(relative)", name: "x", kind: "folder", isDirectory: true,
                                        isEstimated: false), .systemData, relative)
        }
        XCTAssertEqual(policy.block(path: "\(home)/.config", name: ".config", kind: "folder", isDirectory: true,
                                    isEstimated: false), .containsProtectedLocation)
        XCTAssertNil(policy.block(path: "\(home)/.config/fixture", name: "fixture", kind: "folder",
                                  isDirectory: true, isEstimated: false))
    }

    /// Uninstall never offers a layer-1 location, nor a folder holding one;
    /// an app's own leftovers, Apple's App Store apps included, still qualify.
    func testUninstallNeverOffersALocationNoFlowMayTouch() throws {
        let homeURL = try TestFileSystem.makeOperationHome(for: self)
        let home = homeURL.path
        let refused = Self.layerOneSamples.map(\.relative).filter { $0.hasPrefix("Library/") } + [
            "Library/Application Support/Knowledge/knowledgeC.db", "Library/Application Support/KNOWLEDGE",
            "Library/Application Support/AddressBook", "Library/Application Support/CloudDocs",
            "Library/Group Containers/group.is.workflow.my.app",
        ] + ProtectedLocations.appDataRelativePaths
        for relative in refused {
            XCTAssertFalse(AppUninstallService.isSafeRelatedPath("\(home)/\(relative)", homeDirectory: homeURL), relative)
        }
        for relative in [
            "Library/Preferences/com.example.Tool.plist", "Library/Containers/com.example.Tool",
            "Library/Containers/com.apple.iWork.Keynote", "Library/Group Containers/ABCDE12345.com.example.shared",
            "Library/Application Support/Example Tool", "Library/Caches/com.example.Tool",
            "Library/Application Support/KnowledgeBase Pro",
        ] {
            XCTAssertTrue(AppUninstallService.isSafeRelatedPath("\(home)/\(relative)", homeDirectory: homeURL), relative)
        }
    }

    /// Layer 1 in the rule check: no rule, of any action, may start inside
    /// such a location. A root that only holds one (`.cargo`) passes; the
    /// scanner then lists none of it. Every rule shipped today passes.
    func testNoRuleMayStartInsideALocationNoFlowMayTouch() throws {
        let bundled = try CleanupRuleSetLoader.loadBundled()
        XCTAssertNoThrow(try CleanupRuleValidator.validate(bundled))
        let userCaches = try XCTUnwrap(bundled.rules.first { $0.id == "system.user-caches" })
        // D227＋旧值：was the reviewed rule `downloads.installers`, retired; another reviewed
        // rule with no safe roots stands in.
        let downloads = try XCTUnwrap(bundled.rules.first { $0.id == "mail.downloaded-attachments" })
        let cases: [(CleanupRule, String, Bool)] = [
            // Automatic: inside its safe roots, so only layer 1 refuses these.
            (userCaches, "Library/Caches/StorageCleanerIntegration-run", true),
            (userCaches, "Library/Caches/com.example.tool", false),
            // Reviewed: no safe roots apply.
            (downloads, ".ssh", true), (downloads, ".config/gh/hosts", true),
            (downloads, "Library/Application Support/Knowledge", true), (downloads, "Library/keychains", true),
            (downloads, "Desktop", false), (downloads, ".cargo", false),
        ]
        for (base, root, refused) in cases {
            let ruleSet = CleanupRuleSet(schemaVersion: 2, rulesVersion: "g4-2", rules: [try rule(base, rootedAt: root)])
            if refused {
                XCTAssertThrowsError(try CleanupRuleValidator.validate(ruleSet), root) { error in
                    XCTAssertEqual(error as? CleanupRuleValidationError, .forbiddenRoot(ruleID: base.id), root)
                }
            } else {
                XCTAssertNoThrow(try CleanupRuleValidator.validate(ruleSet), root)
            }
        }
    }

    /// Layer 3: one set of flags. File Analysis blocked all six before; the
    /// helper and the uninstall check read three and now read the same six,
    /// so each refuses at least what it refused before.
    func testEveryFlowReadsTheSameFileFlags() {
        let fileAnalysisBefore = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND | SF_RESTRICTED | SF_NOUNLINK)
        let helperBefore = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | SF_RESTRICTED)
        XCTAssertEqual(FileProtectionFlags.all, fileAnalysisBefore)
        XCTAssertEqual(FileProtectionFlags.all & helperBefore, helperBefore)
        XCTAssertEqual(FileProtectionFlags.system & UInt32(SF_IMMUTABLE | SF_RESTRICTED), UInt32(SF_IMMUTABLE | SF_RESTRICTED))
        XCTAssertEqual(FileProtectionFlags.owner & UInt32(UF_IMMUTABLE), UInt32(UF_IMMUTABLE))
        for flag in [UF_IMMUTABLE, UF_APPEND] {
            XCTAssertEqual(FileProtectionFlags.lock(UInt32(flag)), .owner)
        }
        for flag in [SF_IMMUTABLE, SF_APPEND, SF_RESTRICTED, SF_NOUNLINK] {
            XCTAssertEqual(FileProtectionFlags.lock(UInt32(flag)), .system)
        }
        XCTAssertEqual(FileProtectionFlags.lock(UInt32(UF_IMMUTABLE | SF_RESTRICTED)), .system, "System wins")
        for flag in [0, UF_HIDDEN, UF_COMPRESSED, UF_NODUMP] {
            XCTAssertEqual(FileProtectionFlags.lock(UInt32(flag)), .none)
        }
    }

    /// An append-only bundle, which the uninstall check let through before,
    /// now reads as locked by its owner, as the helper refuses it.
    func testAnAppendOnlyBundleReadsAsLockedByItsOwner() throws {
        let root = TestFileSystem.uniqueOperationRoot("SCM-G4-2-Flags")
        TestFileSystem.registerCleanup(of: root, for: self)
        let bundle = root.appendingPathComponent("AppendOnly.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        defer { _ = chflags(bundle.path, 0) }
        XCTAssertEqual(UninstallBundleProtection.of(bundle.path), .none)
        XCTAssertEqual(chflags(bundle.path, UInt32(UF_APPEND)), 0, "Owner can set the flag on the fixture")
        XCTAssertEqual(UninstallBundleProtection.of(bundle.path), .userLocked)
        XCTAssertEqual(chflags(bundle.path, 0), 0)
        XCTAssertEqual(UninstallBundleProtection.of(bundle.path), .none)
    }

    /// One sample per kind of layer-1 location, with File Analysis's reason.
    private static let layerOneSamples: [(relative: String, block: FileAnalysisTrashBlock)] = [
        (".ssh", .credentials), (".config/gh", .credentials), (".cargo/credentials.toml", .credentials),
        ("Library/Keychains", .systemData), ("Library/Autosave Information", .systemData),
        ("Library/KEYCHAINS", .systemData), ("Library/Mobile Documents", .cloudStorage),
        ("Library/CloudStorage", .cloudStorage), ("Library/Application Support/Knowledge", .systemData),
        ("Library/Application Support/FileProvider", .systemData), ("Library/Containers/Dock", .systemData),
        ("Library/Group Containers/group.is.workflow.shortcuts", .systemData),
        ("Library/Caches/StorageCleanerIntegration-run", .appData),
        (ProtectedLocations.appDataRelativePaths[0], .appData), (ProtectedLocations.appDataRelativePaths[1], .appData),
    ]

    private func rule(_ base: CleanupRule, rootedAt path: String) throws -> CleanupRule {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        var root = try XCTUnwrap(object["root"] as? [String: Any])
        root["path"] = path
        object["root"] = root
        return try JSONDecoder().decode(CleanupRule.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
