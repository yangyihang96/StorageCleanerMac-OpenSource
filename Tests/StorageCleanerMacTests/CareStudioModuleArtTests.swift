import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D154 batch 3R (D166④): Protection and Space Map have pictures of their own
/// — a shield and bubbles — in the sidebar and on their pages, while the
/// classic Browser Privacy and File Analysis pages keep theirs.
@MainActor
final class CareStudioModuleArtTests: XCTestCase {
    func testProtectionAndSpaceMapShowTheirOwnPictures() {
        XCTAssertEqual(CareStudioModule.protection.art, .protection)
        XCTAssertEqual(CareStudioFamily.protection.art, .protection)
        XCTAssertEqual(CareStudioModule.spaceMap.art, .spaceMap)
        XCTAssertEqual(CareStudioFamily.spaceMap.art, .spaceMap)
        XCTAssertEqual(GeneratedArt.module(for: .privacy), .privacy, "the classic Browser Privacy page keeps the globe and lock")
        XCTAssertEqual(GeneratedArt.module(for: .largeFiles), .fileAnalysis, "the classic File Analysis page keeps its document")
    }

    /// For review (`STORAGE_CLEANER_CARESTUDIO_EVIDENCE`): each module's new
    /// picture beside its old one, at landing size on the module's backdrop
    /// and turned to its colour as the pages draw it (window captures leave
    /// `hueRotation` out).
    func testRendersTheNewPicturesBesideTheOldForReview() async throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_CARESTUDIO_EVIDENCE"] else {
            throw XCTSkip("Review renders are written only when STORAGE_CLEANER_CARESTUDIO_EVIDENCE is set.")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let library = GeneratedArtLibrary(directory: root.appendingPathComponent("Resources/Art", isDirectory: true))
        for art in [GeneratedArt.protection, .privacy, .spaceMap, .fileAnalysis] {
            _ = await library.image(named: art.resourceName(.landing))
        }
        for (name, module, old) in [("protection", CareStudioModule.protection, GeneratedArt.privacy),
                                    ("spacemap", .spaceMap, .fileAnalysis)] {
            for scheme in [ColorScheme.dark, .light] {
                let content = HStack(spacing: 40) {
                    CareStudioArt(module: module, side: 220, art: old)
                    CareStudioArt(module: module, side: 220)
                }
                .padding(40)
                .background(CareStudioBackdrop(family: module.family, fillsOwnFrame: true))
                .environment(\.colorScheme, scheme)
                .environment(\.generatedArtLibrary, library)
                .environment(\.generatedArtWindowVisible, true)
                .environment(\.featureDisablesLayoutAnimations, true)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage, name)
                try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: path)
                        .appendingPathComponent("module-art-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    /// No two sidebar modules share a picture, and each is a module picture
    /// (512 and 192), not a small object.
    func testEverySidebarModuleHasAPictureOfItsOwn() {
        let pictures = CareStudioFamily.allCases.map(\.art)
        XCTAssertEqual(Set(pictures).count, pictures.count, "\(pictures)")
        for art in pictures {
            XCTAssertFalse(art.isTile, "\(art)")
        }
    }
}
