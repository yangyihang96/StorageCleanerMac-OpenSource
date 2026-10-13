import ImageIO
import XCTest
@testable import StorageCleanerMac

final class LightfieldOptionIconTests: XCTestCase {
    private var art: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Art")
    }
    func testManifestEnumAndBothScaleResourcesCorrespondExactly() throws {
        struct Manifest: Decodable {
            struct Icon: Decodable { let name: String; let files: [String] }
            struct Mapping: Decodable { let file: String }
            let pointSize: Int
            let variants: [Int]
            let icons: [Icon]
            let mappings: [Mapping]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: art.appendingPathComponent("lightfield-options.json")))
        XCTAssertEqual(manifest.pointSize, 28)
        XCTAssertEqual(manifest.variants, [56, 84])
        let names = LightfieldOptionIcon.allCases.map(\.rawValue)
        XCTAssertEqual(names.count, 70, "Approved inventory has 70 unique images")
        XCTAssertEqual(Set(names), Set(manifest.icons.map(\.name)))
        XCTAssertEqual(Set(names), Set(manifest.mappings.map { String($0.file.dropLast(4)) }))
        XCTAssertEqual(manifest.mappings.count, 85, "Aliases are preserved rather than silently dropped")
        let expected = Set(LightfieldOptionIcon.allCases.flatMap { icon in
            LightfieldOptionIcon.Variant.allCases.map { icon.resourceName($0) + ".png" }
        })
        XCTAssertEqual(Set(manifest.icons.flatMap(\.files)), expected)
        let actual = try FileManager.default.contentsOfDirectory(atPath: art.path).filter { $0.hasPrefix("opt-") }
        XCTAssertEqual(Set(actual), expected)
        XCTAssertEqual(LightfieldOptionIcon.variant(displayScale: 1), .twoX)
        XCTAssertEqual(LightfieldOptionIcon.variant(displayScale: 2), .twoX)
        XCTAssertEqual(LightfieldOptionIcon.variant(displayScale: 3), .threeX)
    }
    func testEveryOptionDecodesWithAlphaAndExactPixelSize() async throws {
        let library = GeneratedArtLibrary(resolver: .lightfieldOptionsDirectory(art))
        for icon in LightfieldOptionIcon.allCases {
            for variant in LightfieldOptionIcon.Variant.allCases {
                let name = icon.resourceName(variant)
                let loaded = await library.image(named: name)
                let image = try XCTUnwrap(loaded, name)
                XCTAssertEqual(image.width, variant.rawValue, name)
                XCTAssertEqual(image.height, variant.rawValue, name)
                XCTAssertFalse([.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo), name)
                let again = await library.image(named: name)
                XCTAssertTrue(again === image, "Reuses the D58 decode cache")
            }
        }
    }
    func testMissingAndUnreadableOptionYieldNilWithoutRetrying() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let library = GeneratedArtLibrary(resolver: .lightfieldOptionsDirectory(root))
        let absent = await library.image(named: "absent-56")
        XCTAssertNil(absent)
        XCTAssertTrue(library.isKnownMissing(named: "absent-56"))
        try Data("invalid image".utf8).write(to: root.appendingPathComponent("invalid-84.png"))
        let invalid = await library.image(named: "invalid-84")
        XCTAssertNil(invalid)
        XCTAssertTrue(library.isKnownMissing(named: "invalid-84"))
        let again = await library.image(named: "invalid-84")
        XCTAssertNil(again)
    }
}
