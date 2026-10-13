import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D58 illustration set A: every shipped picture decodes with alpha at its
/// exported size, every module and state has one, a missing file falls back
/// to the code-drawn mark, pictures are decorative, and the sidebar keeps
/// its SF Symbol tiles. Reads the repository's `Resources/Art` only.
final class GeneratedArtTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var artDirectory: URL {
        projectRoot.appendingPathComponent("Resources/Art", isDirectory: true)
    }

    func testEveryPictureDecodesWithAlphaAtItsExportedSizeWithinTheSizeBudget() async throws {
        let library = GeneratedArtLibrary(directory: artDirectory)
        var totalBytes = 0
        for art in GeneratedArt.allCases {
            for variant in GeneratedArt.Variant.allCases {
                let name = art.resourceName(variant)
                let url = artDirectory.appendingPathComponent(name).appendingPathExtension("heic")
                let loaded = await library.image(named: name)
                let image = try XCTUnwrap(loaded, name)
                XCTAssertEqual(image.width, variant.rawValue, name)
                XCTAssertEqual(image.height, variant.rawValue, name)
                XCTAssertFalse([.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo), "\(name) keeps its alpha")
                totalBytes += try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            }
        }
        // D70: the four approved benchmark option families are checked as PNG,
        // each at 56/84 px with alpha. Master PNGs remain forbidden. The original HEIC + benchmark
        // scope shares the original 1 MB budget (the limit is not increased).
        let options = GeneratedArtLibrary(resolver: .lightfieldOptionsDirectory(artDirectory))
        var expectedOptions: Set<String> = []
        for family in ["cpu", "gpu", "memory", "storage"] {
            for pixels in [56, 84] {
                let name = "opt-benchmark-\(family)-\(pixels)"
                expectedOptions.insert(name + ".png")
                let loaded = await options.image(named: name)
                let image = try XCTUnwrap(loaded, name)
                XCTAssertEqual(image.width, pixels, name)
                XCTAssertEqual(image.height, pixels, name)
                XCTAssertFalse([.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo), "\(name) keeps its alpha")
                let url = artDirectory.appendingPathComponent(name).appendingPathExtension("png")
                totalBytes += try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: artDirectory.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".heic") }.count, GeneratedArt.allCases.count * 2)
        // D70 permits the approved alpha-preserving option thumbnails only;
        // D58 module/state PNG masters are still forbidden in the bundle.
        let optionFiles = Set(LightfieldOptionIcon.allCases.flatMap { icon in
            LightfieldOptionIcon.Variant.allCases.map { icon.resourceName($0) + ".png" }
        })
        // D77/user 2026-10-11: four separate 192/512 alpha scope icons.
        // Keep the original module/mini-option budgets; no master is shipped.
        var scopeFiles = Set<String>(), scopeBytes = 0
        for family in ["cache", "logs", "temporary", "downloads"] {
            for pixels in [192, 512] {
                let name = "scope-cleanup-\(family)-\(pixels)"
                scopeFiles.insert(name + ".png")
                let loaded = await options.image(named: name)
                let image = try XCTUnwrap(loaded, name)
                XCTAssertEqual(image.width, pixels, name)
                XCTAssertEqual(image.height, pixels, name)
                XCTAssertFalse([.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo), name)
                scopeBytes += try XCTUnwrap(artDirectory.appendingPathComponent(name + ".png")
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize, name)
            }
        }
        XCTAssertLessThan(scopeBytes, 1_000_000, "D77 separate four-scope export budget")
        XCTAssertEqual(Set(files.filter { $0.hasSuffix(".png") }), optionFiles.union(scopeFiles))
        XCTAssertEqual(Set(files.filter { $0.hasPrefix("opt-benchmark-") && $0.hasSuffix(".png") }), expectedOptions)
        XCTAssertTrue(files.contains("README.md"))
        XCTAssertLessThan(totalBytes, 1_000_000)
        // Keep the stricter 1 MB option budget when uniting both inventories;
        // no unknown file size can silently count as zero.
        let optionBytes = try optionFiles.reduce(0) { sum, name in
            sum + (try XCTUnwrap(artDirectory.appendingPathComponent(name)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize, name))
        }
        XCTAssertLessThan(optionBytes, 1_000_000, "D70 option PNG budget")
    }

    func testEveryModuleAndStateHasAPicture() {
        for filter in ReviewFilter.allCases where filter != .utilityHub {
            XCTAssertNotNil(GeneratedArt.module(for: filter), filter.rawValue)
            XCTAssertEqual(GeneratedArt.module(forSystemImage: filter.systemImage),
                           GeneratedArt.module(for: filter), filter.rawValue)
        }
        XCTAssertNil(GeneratedArt.module(for: .utilityHub))
        XCTAssertEqual(GeneratedArt.module(forSystemImage: GeneratedArt.similarPhotosSystemImage), .similarPhotos)
        XCTAssertEqual(GeneratedArt.module(forSystemImage: GeneratedArt.performanceDashboardSystemImage), .benchmark)
        XCTAssertNil(GeneratedArt.module(forSystemImage: "exclamationmark.triangle.fill"))
        let states = GeneratedArt.allCases.filter { $0.rawValue.hasPrefix("state-") }
        XCTAssertEqual(Set(states), [.stateSuccess, .stateAllClear, .stateEmpty, .statePermission, .stateError])
    }

    func testPicturesDecodeOnceAndAMissingFileFallsBack() async throws {
        let library = GeneratedArtLibrary(directory: artDirectory)
        let name = GeneratedArt.memory.resourceName(.header)
        XCTAssertNil(library.cachedImage(named: name), "nothing is read before it is asked for")
        let loaded = await library.image(named: name)
        let first = try XCTUnwrap(loaded)
        let reloaded = await library.image(named: name)
        let second = try XCTUnwrap(reloaded)
        XCTAssertTrue(first === second, "A picture is decoded once and kept")
        XCTAssertTrue(library.cachedImage(named: name) === first)

        let empty = try TestFileSystem.makeHome(for: self)
        let missing = GeneratedArtLibrary(directory: empty)
        let absent = await missing.image(named: name)
        XCTAssertNil(absent)
        XCTAssertTrue(missing.isKnownMissing(named: name), "a missing file is not looked up again")
        let again = await missing.image(named: name)
        XCTAssertNil(again)
    }

    func testPicturesAreDecorativeAndOnlyOnTheAgreedSurfaces() throws {
        func source(_ path: String) throws -> String {
            try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        }
        let view = try source("Sources/StorageCleanerMac/Views/DesignSystem/GeneratedArtView.swift")
        XCTAssertTrue(view.contains("Image(decorative: image, scale: 2)"))
        XCTAssertTrue(view.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(view.contains("fallback"))
        // Header marks from the regular form up; the 32 pt compact header
        // keeps the code-drawn tile.
        let hero = try source("Sources/StorageCleanerMac/Views/DesignSystem/PageHero.swift")
        // D64: header marks are gone; central decorative art remains.
        XCTAssertFalse(hero.contains("GeneratedArtView("))
        XCTAssertFalse(hero.contains("IconTile("))
        XCTAssertTrue(hero.contains("Text(title)"))
        // D67/D72: the approved central artwork resolves from the module rather
        // than a removed header symbol; the performance mapping must stay benchmark.
        let performance = try source("Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkWorkspaceView.swift")
        let performanceLanding = try source("Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkLandingView.swift")
        XCTAssertTrue(performanceLanding.contains("FeatureLightfieldPage(module: .performance, phase: .landing"))
        XCTAssertEqual(GeneratedArt.module(for: .performance), .benchmark)
        let lightfield = try source("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfield.swift")
        XCTAssertTrue(lightfield.contains("FeatureLightfieldArtwork(art: artwork ?? GeneratedArt.module(for: module), variant: compactResult ? .header : .landing)"), "D77 result uses only the small header art")
        XCTAssertTrue(lightfield.contains("Image(decorative: picture, scale: 2)"))
        XCTAssertTrue(lightfield.contains(".allowsHitTesting(false).accessibilityHidden(true)"))
        XCTAssertTrue(performance.contains("PerformanceBenchmarkLandingView("))
        // D67 replaces clickable navigation tiles with the approved artwork thumbnails.
        let sidebar = try source("Sources/StorageCleanerMac/Views/SidebarView.swift")
        XCTAssertTrue(sidebar.contains("FeatureLightfieldArtwork(art:"))
        XCTAssertTrue(sidebar.contains(".frame(width: 20, height: 20)"))
        // Orbits, nodes, stars and halo stay code-drawn around the picture,
        // and the drawing never runs a loop while idle.
        let orbit = try source("Sources/StorageCleanerMac/Views/DesignSystem/OrbitLandingArtwork.swift")
        XCTAssertTrue(orbit.contains("GeneratedArtView(art: centerArt, variant: .landing)"))
        XCTAssertTrue(orbit.contains("if isActive {"))
        // D62②④: motion also requires activity, visibility and an attached visible window.
        XCTAssertTrue(orbit.contains("turns: AppMotion.runsOrbit(isActive: isActive, isVisible: isVisible, reduceMotion: reduceMotion)"))
        XCTAssertTrue(orbit.contains("guard turns, window != nil, window?.isVisible == true"))
        XCTAssertTrue(orbit.contains("window?.isMiniaturized == false"))
        XCTAssertTrue(orbit.contains("!isHiddenOrHasHiddenAncestor"))
        XCTAssertTrue(orbit.contains("window?.occlusionState.contains(.visible) == true"))
        XCTAssertTrue(orbit.contains("rotation.duration = AppMotion.orbitRotationDuration"))
        // Shipped by both bundle scripts.
        for script in ["script/build_and_run.sh", "script/make_release_dmg.sh"] {
            XCTAssertTrue(try source(script).contains("\"$ROOT_DIR\"/Resources/Art/*.heic"), script)
            XCTAssertTrue(try source(script).contains("\"$ROOT_DIR\"/Resources/Art/opt-benchmark-*.png"), script)
        }
    }

    /// The shared library reads the app bundle; in the SwiftPM test host
    /// (xctest is the main bundle) it finds nothing, and views fall back
    /// without crashing. The real files are resolved through an injected
    /// library in `DesignSystemV2ReviewTests` (review P2-6).
    func testTheSharedLibraryInTheTestHostFallsBack() async {
        let loaded = await GeneratedArtLibrary.shared.image(named: GeneratedArt.smartScan.resourceName(.landing))
        XCTAssertNil(loaded)
        XCTAssertNil(GeneratedArt.smartScan.cachedImage(.header))
    }
}
