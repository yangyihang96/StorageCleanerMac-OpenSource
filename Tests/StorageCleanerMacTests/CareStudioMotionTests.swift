#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D154: CleanMyMac-style motion — a landing picture swings in, a success
/// mark pops with a ring of light, result tiles come in one after another,
/// a working picture has a turning ring. All of it rests on the still layout
/// and stays still under Reduce Motion and in test captures.
@MainActor
final class CareStudioMotionTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testPicturesArriveFromTheirStartAndRestAsThemselves() {
        // A landing picture starts lower, tilted, smaller and clear.
        let start = CareStudioArt.arrivalPose(entrance: true, success: false, still: false, arrived: false)
        XCTAssertGreaterThan(start.lift, 0)
        XCTAssertLessThan(start.rotation, 0)
        XCTAssertLessThan(start.scale, 1)
        XCTAssertEqual(start.opacity, 0)
        // A success mark pops from small, in place.
        let pop = CareStudioArt.arrivalPose(entrance: false, success: true, still: false, arrived: false)
        XCTAssertEqual(pop.lift, 0)
        XCTAssertLessThan(pop.scale, 1)
        // At rest, still, or with nothing to arrive, the picture is itself.
        for pose in [CareStudioArt.arrivalPose(entrance: true, success: false, still: false, arrived: true),
                     CareStudioArt.arrivalPose(entrance: true, success: true, still: true, arrived: false),
                     CareStudioArt.arrivalPose(entrance: false, success: false, still: false, arrived: false)] {
            XCTAssertEqual(pose.scale, 1)
            XCTAssertEqual(pose.rotation, 0)
            XCTAssertEqual(pose.lift, 0)
            XCTAssertEqual(pose.opacity, 1)
        }
    }

    /// Report §4 item 17 (CleanMyMac's page change): halfway in, a page is
    /// blurred — its edge spills grey past itself — and once in it is sharp.
    func testAPageComesInOutOfABlur() throws {
        func render(_ opacity: Double) throws -> NSBitmapImageRep {
            let page = Rectangle().fill(Color.black).frame(width: 40, height: 40)
                .modifier(AppMotionPageModifier(opacity: opacity, offset: 0))
                .frame(width: 120, height: 120)
                .background(Color.white)
            let renderer = ImageRenderer(content: page)
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        }
        /// The brightness two points left of the square's left edge.
        func outside(_ bitmap: NSBitmapImageRep) throws -> CGFloat {
            try XCTUnwrap(bitmap.colorAt(x: 38, y: 60)?.usingColorSpace(.sRGB)).brightnessComponent
        }
        XCTAssertLessThan(try outside(render(0.5)), 0.97, "halfway in, the page's edge is blurred")
        XCTAssertGreaterThan(try outside(render(1)), 0.99, "in, the page is sharp")
        XCTAssertEqual(AppMotion.pageBlurRadius, 8)
    }

    func testTilesComeInOneAfterAnotherWithABoundedDelay() {
        XCTAssertEqual(CareStudioMotion.tileDelay(0), 0)
        XCTAssertEqual(CareStudioMotion.tileDelay(1), CareStudioMotion.tileStagger, accuracy: 1e-9)
        XCTAssertEqual(CareStudioMotion.tileDelay(30), CareStudioMotion.tileDelay(9), accuracy: 1e-9)
        XCTAssertLessThanOrEqual(CareStudioMotion.tileDelay(100), 0.5)
    }

    func testMotionStaysStillUnderReduceMotionAndInCaptures() throws {
        let hero = try source("Sources/StorageCleanerMac/Views/CareStudio/CareStudioHero.swift")
        XCTAssertTrue(hero.contains("private var still: Bool { reduceMotion || disablesAnimations }"))
        XCTAssertTrue(hero.contains("if isWorking && !reduceMotion {"))
        XCTAssertTrue(hero.contains("if showsSuccess && arrives {"))
        let tiles = try source("Sources/StorageCleanerMac/Views/CareStudio/CareStudioJunkResults.swift")
        XCTAssertTrue(tiles.contains("private var still: Bool { reduceMotion || disablesAnimations }"))
        XCTAssertTrue(tiles.contains(".modifier(CareStudioTileArrival(index: index, arrived: arrived || still))"))
        XCTAssertTrue(tiles.contains(".onAppear { if !still { arrived = true } }"))
        // Every landing picture swings in; running and done pictures do not.
        let pages = try source("Sources/StorageCleanerMac/Views/CareStudio/CareStudioPages.swift")
        XCTAssertEqual(pages.components(separatedBy: "entrance: true)").count - 1, 2)
        let template = try source("Sources/StorageCleanerMac/Views/CareStudio/CareStudioTemplatePages.swift")
        XCTAssertTrue(template.contains("CareStudioArt(module: studio, side: side, art: artwork, entrance: true)"))
        XCTAssertFalse(template.contains("isWorking: true, art: artwork, entrance: true"))
    }
}
#endif
