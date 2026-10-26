#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D-FP1–D-FP6: renders the new tool pages off screen with fixture data (no
/// scan of this Mac, no file moved). PNGs are written only when
/// `STORAGE_CLEANER_TOOLBOX_EVIDENCE` names a directory.
@MainActor
final class ToolboxRenderReviewTests: XCTestCase {
    static let detailSize = CGSize(width: 1_070, height: 735)
    static let compactSize = CGSize(width: 780, height: 540)

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func preloadedArt() async -> GeneratedArtLibrary {
        let library = GeneratedArtLibrary(directory: projectRoot.appendingPathComponent("Resources/Art", isDirectory: true))
        for art in GeneratedArt.allCases {
            _ = await library.image(named: art.resourceName(.landing))
        }
        return library
    }

    @discardableResult
    func render<V: View>(_ view: V, name: String, size: CGSize = detailSize, scheme: ColorScheme,
                         library: GeneratedArtLibrary) throws -> NSBitmapImageRep {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)
            .environment(\.generatedArtLibrary, library)
            .environment(\.generatedArtWindowVisible, true)
            .environment(\.featureDisablesLayoutAnimations, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, name)
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, size.width, accuracy: 0.5, name)
        if let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_TOOLBOX_EVIDENCE"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    static func extensionInventory() -> ExtensionInventory {
        func item(_ kind: ExtensionKind, _ name: String, bytes: Int64, domain: ExtensionDomain = .user,
                  signing: ExtensionSigning = .developer(teamID: "ABCDE12345", name: "Example Ltd"),
                  obsolete: ExtensionObsolescence? = nil, management: ExtensionManagement = .movableToTrash,
                  parent: String? = nil, point: String? = nil, election: ExtensionElection? = nil) -> ExtensionItem {
            ExtensionItem(kind: kind, path: "/Users/fixture/Library/\(kind.rawValue)/\(name)", name: name,
                          bundleIdentifier: "com.example.\(name.lowercased())", version: "2.1", domain: domain,
                          bytes: bytes, sizeIsLowerBound: false, signing: signing, parentName: parent,
                          parentPath: parent.map { "/Applications/\($0).app" }, election: election,
                          extensionPoint: point, obsolescence: obsolete, isSymbolicLink: false,
                          identity: FileIdentity(deviceID: 1, inode: UInt64(abs(name.hashValue % 100_000)) + 1,
                                                 entryKind: .directory, creationTimeNanoseconds: nil),
                          modified: nil, management: management)
        }
        return ExtensionInventory(items: [
            item(.preferencePane, "Fuse for macOS", bytes: 2_400_000),
            item(.preferencePane, "Java", bytes: 640_000, domain: .local, management: .administratorLocation),
            item(.internetPlugin, "Silverlight", bytes: 18_300_000, domain: .local, obsolete: .npapiRetired,
                 management: .administratorLocation),
            item(.quickLookGenerator, "QLMarkdown", bytes: 9_800_000, obsolete: .quickLookGeneratorsRetired),
            item(.quickLookGenerator, "QuickLookJSON", bytes: 420_000, signing: .unsigned, obsolete: .quickLookGeneratorsRetired),
            item(.spotlightImporter, "Sketch Importer", bytes: 1_100_000),
            item(.audioPlugin, "Vintage Synth", bytes: 88_000_000),
            item(.kernelExtension, "Vendor Audio Driver", bytes: 900_000, domain: .local, management: .systemSettingsApproval),
            item(.safariExtension, "Ad Blocker", bytes: 0, signing: .notChecked, management: .safariSettings,
                 parent: "Blocker", point: "com.apple.Safari.content-blocker"),
            item(.appExtension, "Notes Widget", bytes: 0, signing: .notChecked,
                 management: .withParentApplication("Notes Pro"), parent: "Notes Pro",
                 point: "com.apple.widgetkit-extension", election: .disabled),
        ], hiddenAppleExtensionCount: 502, pluginKitAvailable: true, scannedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testRendersExtensionManagerForReview() async throws {
        let library = await preloadedArt()
        let inventory = Self.extensionInventory()
        for (language, scheme) in [(AppLanguage.zhHans, ColorScheme.dark), (.zhHans, .light), (.english, .dark)] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let suffix = (language == .english ? "en" : "zh") + (scheme == .dark ? "-dark" : "-light")
            let store = ExtensionManagerStore(coordinator: HeavyWorkCoordinator(), openURL: { _ in })
            let quickLook = inventory.items(of: .quickLookGenerator).map(\.id)
            store.installPreview(inventory: inventory, selection: Set(quickLook), outcome: ExtensionRemovalOutcome(
                removed: [.init(path: "/x/Old.qlgenerator", name: "Old", note: nil)], removedBytes: 3_200_000,
                kept: [.init(path: "/x/Tool.prefPane", name: "Tool",
                             note: ExtensionRemovalService.describe(.relatedAppStillRunning))]))
            try render(ExtensionManagerPage(store: store, module: .startup, onBack: {}),
                       name: "fp1-extensions-\(suffix)", scheme: scheme, library: library)
            try render(ExtensionManagerPage(store: store, module: .startup, onBack: {}),
                       name: "fp1-extensions-compact-\(suffix)", size: Self.compactSize, scheme: scheme, library: library)
            let empty = ExtensionManagerStore(coordinator: HeavyWorkCoordinator(), openURL: { _ in })
            try render(CareStudioRunningPage(module: .startup, title: L10n.text("正在查找扩展…", "Finding Extensions…"),
                                             detail: L10n.text("只读取，不改动任何文件", "Reading only; nothing is changed"),
                                             onStop: {}),
                       name: "fp1-extensions-running-\(suffix)", scheme: scheme, library: library)
            _ = empty
        }
    }

    /// D-FP3: without Full Disk Access the Chat Files page explains why and
    /// links to the setting instead of reading anything.
    func testRendersChatFilesAccessGuideForReview() async throws {
        let library = await preloadedArt()
        for (language, scheme) in [(AppLanguage.zhHans, ColorScheme.dark), (.zhHans, .light), (.english, .dark)] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            var scanner = ChatFilesScanner()
            scanner.fullDiskAccess = { .notVerified }
            let store = ChatFilesStore(coordinator: HeavyWorkCoordinator(), scanner: scanner, loadVolumes: { [] },
                                       openURL: { _ in })
            store.scan()
            XCTAssertEqual(store.phase, .needsFullDiskAccess)
            let suffix = (language == .english ? "en" : "zh") + (scheme == .dark ? "-dark" : "-light")
            try render(ChatFilesPage(store: store, module: .startup, onBack: {}),
                       name: "fp3-chat-access-\(suffix)", scheme: scheme, library: library)
        }
    }
}
#endif
