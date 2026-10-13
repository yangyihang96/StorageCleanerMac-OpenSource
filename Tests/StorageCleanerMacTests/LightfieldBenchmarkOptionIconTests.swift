import ImageIO
import XCTest
@testable import StorageCleanerMac

/// This batch owns four benchmark families, with the same two PNG variants as
/// B2. D70 also ships the other families; both inventories remain exact.
final class LightfieldBenchmarkOptionIconTests: XCTestCase {
    private let icons: [LightfieldOptionIcon] = [
        .benchmarkCpu, .benchmarkGpu, .benchmarkMemory, .benchmarkStorage
    ]
    private var art: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Art")
    }

    func testBenchmarkFamiliesAndBothScaleResourcesCorrespondExactly() throws {
        XCTAssertEqual(LightfieldOptionIcon.allCases.count, 70, "The upstream enum is not narrowed to this batch")
        XCTAssertEqual(LightfieldOptionIcon.pointSize, 28)
        XCTAssertEqual(LightfieldOptionIcon.Variant.allCases.map(\.rawValue), [56, 84])
        XCTAssertEqual(icons.map(\.rawValue), [
            "opt-benchmark-cpu", "opt-benchmark-gpu", "opt-benchmark-memory", "opt-benchmark-storage"
        ])
        let expected = Set(icons.flatMap { icon in
            LightfieldOptionIcon.Variant.allCases.map { icon.resourceName($0) + ".png" }
        })
        let actual = try FileManager.default.contentsOfDirectory(atPath: art.path)
            .filter { $0.hasPrefix("opt-") }
        XCTAssertEqual(expected.count, 8)
        XCTAssertEqual(Set(actual.filter { $0.hasPrefix("opt-benchmark-") }), expected)
        let allExpected = Set(LightfieldOptionIcon.allCases.flatMap { icon in
            LightfieldOptionIcon.Variant.allCases.map { icon.resourceName($0) + ".png" }
        })
        XCTAssertEqual(allExpected.count, 140)
        XCTAssertEqual(Set(actual), allExpected)
        XCTAssertEqual(LightfieldOptionIcon.variant(displayScale: 1), .twoX)
        XCTAssertEqual(LightfieldOptionIcon.variant(displayScale: 2), .twoX)
        XCTAssertEqual(LightfieldOptionIcon.variant(displayScale: 3), .threeX)
    }

    func testEveryBenchmarkOptionDecodesWithAlphaExactPixelSizeAndSharedCache() async throws {
        let library = GeneratedArtLibrary(resolver: .lightfieldOptionsDirectory(art))
        for icon in icons {
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

    func testPNGOptionsResolveFromArtInsideAnIsolatedBundle() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let bundle = root.appendingPathComponent("BenchmarkOptions.bundle", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources/Art", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.storagecleanermac.tests.benchmark-options",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNotNil(Bundle(url: bundle))
        for icon in icons {
            for variant in LightfieldOptionIcon.Variant.allCases {
                let name = icon.resourceName(variant) + ".png"
                try FileManager.default.copyItem(at: art.appendingPathComponent(name),
                                                to: resources.appendingPathComponent(name))
            }
        }
        let library = GeneratedArtLibrary(resolver: .lightfieldOptionsBundle(bundle))
        for icon in icons {
            for variant in LightfieldOptionIcon.Variant.allCases {
                let name = icon.resourceName(variant)
                let loaded = await library.image(named: name)
                let image = try XCTUnwrap(loaded, name)
                XCTAssertEqual(image.width, variant.rawValue, name)
                XCTAssertEqual(image.height, variant.rawValue, name)
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
