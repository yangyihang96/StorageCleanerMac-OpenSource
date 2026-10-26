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

    /// The D58 set; D166 pictures are checked against their own budget.
    private static let d58: Set<GeneratedArt> = [
        .smartScan, .cleanup, .devCaches, .health, .privacy, .benchmark, .startup, .memory, .energy,
        .uninstall, .updater, .fileAnalysis, .migration, .duplicates, .similarPhotos,
        .stateSuccess, .stateAllClear, .stateEmpty, .statePermission, .stateError,
    ]

    func testEveryPictureDecodesWithAlphaAtItsExportedSizeWithinTheSizeBudget() async throws {
        let library = GeneratedArtLibrary(directory: artDirectory)
        var totalBytes = 0
        var d166Bytes = 0
        for art in GeneratedArt.allCases {
            // D166: tiles ship the header size only (was GeneratedArt.Variant.allCases for every picture).
            for variant in art.variants {
                let name = art.resourceName(variant)
                let url = artDirectory.appendingPathComponent(name).appendingPathExtension("heic")
                let loaded = await library.image(named: name)
                let image = try XCTUnwrap(loaded, name)
                XCTAssertEqual(image.width, variant.rawValue, name)
                XCTAssertEqual(image.height, variant.rawValue, name)
                XCTAssertFalse([.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo), "\(name) keeps its alpha")
                let bytes = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                if Self.d58.contains(art) { totalBytes += bytes } else { d166Bytes += bytes }
            }
        }
        // D166: the added pictures get their own 1 MB; the D58 budget below is unchanged.
        XCTAssertLessThan(d166Bytes, 1_000_000, "D166 picture budget")
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
        // D166: tiles ship one size (was GeneratedArt.allCases.count * 2).
        XCTAssertEqual(files.filter { $0.hasSuffix(".heic") }.count,
                       GeneratedArt.allCases.map(\.variants.count).reduce(0, +))
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
        // D166 adds .stateCelebration (was the five states before it).
        XCTAssertEqual(Set(states), [.stateSuccess, .stateAllClear, .stateEmpty, .statePermission, .stateError,
                                     .stateCelebration])
    }

    /// D166: the module pages reference these names, so they are pinned;
    /// tiles ship and preload nothing beyond their header picture.
    func testD166PicturesKeepTheirNamesAndTilesShipOneSize() {
        let added = GeneratedArt.allCases.filter { !Self.d58.contains($0) }
        // D166② adds the two first-run pictures and five tiles (was the 48 names
        // without "onboard-welcome", "onboard-diskaccess", "tile-notifications",
        // "tile-general", "tile-miniwindow", "tile-scansafety", "tile-systemcontrol").
        // D166③ adds six tool sidebar tiles (was the 55 names above, without
        // "tile-purgeable" through "tile-appextension").
        // D166④ adds two module hero pictures (was the 61 names above, without
        // "module-protection" and "module-spacemap").
        XCTAssertEqual(added.map(\.rawValue), [
            "module-performance", "module-apps", "module-clutter", "module-cloudcleanup", "module-mytools",
            "module-myactivity", "module-extensions", "module-maintenance", "module-chatfiles", "state-celebration",
            "onboard-welcome", "onboard-diskaccess",
            "tile-systemjunk", "tile-devjunk", "tile-aiclutter", "tile-mail", "tile-trash", "tile-review",
            "tile-appupdates", "tile-unused", "tile-leftovers", "tile-installers", "tile-legacyapps",
            "tile-systemupdate", "tile-pickapps", "tile-appstore", "tile-othersources", "tile-vendors",
            "tile-compare", "tile-maintenance", "tile-loginitems", "tile-background", "tile-sync", "tile-attention",
            "tile-pressure", "tile-topapps", "tile-freeable", "tile-processes", "tile-history", "tile-sensitive",
            "tile-cookies", "tile-browsers", "tile-downloaded", "tile-largecloud", "tile-cloudonly",
            "tile-otherclouds", "tile-cleaned", "tile-month", "tile-count", "tile-restore",
            "tile-notifications", "tile-general", "tile-miniwindow", "tile-scansafety", "tile-systemcontrol",
            "tile-purgeable", "tile-permissions", "tile-quicklook", "tile-screensaver", "tile-audio",
            "tile-appextension",
            "module-protection", "module-spacemap",
        ])
        for art in GeneratedArt.allCases {
            if art.isTile {
                XCTAssertEqual(art.variants, [.header], art.rawValue)
                XCTAssertEqual(art.resourceName(.landing), art.rawValue + "-192", art.rawValue)
            } else {
                XCTAssertEqual(art.variants, [.header, .landing], art.rawValue)
                XCTAssertEqual(art.resourceName(.landing), art.rawValue + "-512", art.rawValue)
            }
        }
        let preloaded = GeneratedArt.headerResourceNames
        // D166②: the two first-run pictures are preloaded too (was 30);
        // D166④: and the two new module pictures (was 32).
        XCTAssertEqual(preloaded.count, 34)
        XCTAssertFalse(preloaded.contains { $0.hasPrefix("tile-") })
    }

    /// D166: every module and tile picture (the D58 ones remade in Blender
    /// too) is one hue, and `dominantHue` (which turns it to a module colour)
    /// is the one measured on its header export. The five D58 states keep the
    /// values their success rotation assumes.
    func testD166DominantHuesMatchTheirPictures() async throws {
        let library = GeneratedArtLibrary(directory: artDirectory)
        let d58States: Set<GeneratedArt> = [.stateSuccess, .stateAllClear, .stateEmpty, .statePermission, .stateError]
        for art in GeneratedArt.allCases where !d58States.contains(art) {
            let loaded = await library.image(named: art.resourceName(.header))
            let image = try XCTUnwrap(loaded, art.rawValue)
            let measured = try XCTUnwrap(Self.bodyHue(of: image), art.rawValue)
            XCTAssertGreaterThan(measured.purity, 0.9, "\(art.rawValue) is one hue")
            let delta = abs((measured.hue - art.dominantHue + 540).truncatingRemainder(dividingBy: 360) - 180)
            XCTAssertLessThan(delta, 10, "\(art.rawValue) measures \(Int(measured.hue))°")
        }
    }

    /// Circular mean hue over opaque, coloured pixels, weighted by
    /// alpha × saturation × brightness; purity 1 means a single hue.
    private static func bodyHue(of image: CGImage) -> (hue: Double, purity: Double)? {
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var x = 0.0, y = 0.0, total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha >= 0.5 else { continue }
            func channel(_ offset: Int) -> Double { min(1, Double(pixels[index + offset]) / 255 / alpha) }
            let color = NSColor(srgbRed: channel(0), green: channel(1), blue: channel(2), alpha: 1)
            let saturation = color.saturationComponent, brightness = color.brightnessComponent
            guard saturation >= 0.15, brightness >= 0.15 else { continue }
            let weight = alpha * saturation * brightness, angle = color.hueComponent * 2 * .pi
            x += weight * cos(angle)
            y += weight * sin(angle)
            total += weight
        }
        guard total > 0 else { return nil }
        return ((atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360), hypot(x, y) / total)
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
        // D154: CleanMyMac-sized module marks (26 pt) in the module sidebar.
        XCTAssertTrue(sidebar.contains("static let glyphSide: CGFloat = 26"))
        XCTAssertTrue(sidebar.contains(".frame(width: Self.glyphSide, height: Self.glyphSide)"))
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
