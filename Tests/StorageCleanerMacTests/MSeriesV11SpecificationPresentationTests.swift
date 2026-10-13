import Foundation
import XCTest
@testable import StorageCleanerMac

final class MSeriesV11SpecificationPresentationTests: XCTestCase {
    private func loaded() -> AppleSiliconCatalogLoader.Loaded {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Benchmark")
        return AppleSiliconCatalogLoader.load(catalogURL: resources.appendingPathComponent("AppleSiliconCatalog.json"),
            manifestURL: resources.appendingPathComponent("AppleSiliconCatalog.manifest.json"))
    }
    func testEveryPeerSKUFieldUsesItsOwnCatalogSourceAndKeepsMissingUnknown() throws {
        let catalog = try XCTUnwrap(loaded().catalog)
        var count = 0
        for peer in catalog.chips {
            for index in peer.skus.indices {
                let rows = MSeriesV11PagePresentation.specificationRows(peer, skuIndex: index)
                XCTAssertEqual(rows.count, 3)
                XCTAssertEqual(Set(rows.map(\.field)).count, 3)
                for row in rows {
                    count += 1
                    XCTAssertEqual(row.peerID, peer.id)
                    XCTAssertEqual(row.skuID, peer.skus[index].id)
                    XCTAssertEqual(row.sources.map(\.absoluteString), peer.sources[row.field] ?? [])
                    XCTAssertTrue(row.sourceLabel.contains(peer.marketingName))
                    XCTAssertTrue(row.sourceLabel.contains(peer.skus[index].id))
                    XCTAssertTrue(row.sourceLabel.contains(row.title))
                    if peer.unverified.contains(where: { $0.field == row.field }) || row.sources.isEmpty {
                        XCTAssertNil(row.value)
                        XCTAssertNotNil(row.unknownReason)
                    }
                    if row.title == "GB/s", peer.skus[index].memoryBandwidthGBps == nil { XCTAssertNil(row.value) }
                }
            }
        }
        XCTAssertGreaterThan(count, 60, "the complete catalog must be exercised, not only the current chip")
    }

    func testPeerSourcesNeverInheritCurrentChipAndUnverifiedValueNeverBecomesZero() throws {
        let chip = try XCTUnwrap(loaded().catalog?.chips.first { $0.id == "m5-pro" })
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(chip)) as? [String: Any])
        let fields = ["/cpu/0/totalCores", "/skus/0/gpuCores", "/skus/0/memoryBandwidthGBps"]
        object["sources"] = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($0.element, ["https://peer.example/field-\($0.offset)"]) })
        let peer = try JSONDecoder().decode(AppleSiliconCatalog.Chip.self, from: JSONSerialization.data(withJSONObject: object))
        let rows = MSeriesV11PagePresentation.specificationRows(peer, skuIndex: 0)
        for index in rows.indices {
            XCTAssertEqual(rows[index].sources.map(\.absoluteString), ["https://peer.example/field-\(index)"])
            XCTAssertNotNil(rows[index].value)
        }
        object["unverified"] = [["field": fields[2], "reason": "conflicting SKU evidence", "checkedSources": ["https://peer.example/checked"]]]
        let unverified = try JSONDecoder().decode(AppleSiliconCatalog.Chip.self, from: JSONSerialization.data(withJSONObject: object))
        let unknown = try XCTUnwrap(MSeriesV11PagePresentation.specificationRows(unverified, skuIndex: 0).last)
        XCTAssertNil(unknown.value)
        XCTAssertEqual(unknown.unknownReason, "conflicting SKU evidence")
        XCTAssertEqual(unknown.sources.map(\.absoluteString), ["https://peer.example/field-2"])
        object["sources"] = [:]
        let missing = try JSONDecoder().decode(AppleSiliconCatalog.Chip.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(MSeriesV11PagePresentation.specificationRows(missing, skuIndex: 0).allSatisfy { $0.value == nil })
    }
}
