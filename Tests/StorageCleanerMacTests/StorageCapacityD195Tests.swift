import XCTest
@testable import StorageCleanerMac

@MainActor
final class StorageCapacityD195Tests: XCTestCase {
    func testActivityAndSpaceMapShowTheSameFinderUsageAndKeepStrictFreeBytes() throws {
        let capacity = StorageCapacitySnapshot(totalBytes: 994_610_000_000, availableBytes: 77_540_000_000,
                                               availableForImportantUsageBytes: 204_220_000_000)
        let index = SpaceMapMemoryIndex.make(rootPath: "/Fixture", children: [.file("a", 100)])
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath, using: index)
        let result = StorageMapAnalysisResult(target: .init(path: index.rootPath, title: "Fixture", kind: .internalVolume),
            volumeTotalBytes: capacity.totalBytes, volumeAvailableBytes: capacity.userAvailableBytes,
            inspectedItemCount: 1, omittedItemCount: 0, scanSeconds: 1, index: index, rootSnapshot: snapshot)
        let info = MyActivityMacInfo(capacity: capacity)
        XCTAssertEqual(result.usedVolumeBytes, capacity.userUsedBytes)
        XCTAssertEqual(result.usedVolumeBytes, 790_390_000_000)
        XCTAssertEqual(capacity.usedBytes, 917_070_000_000, "health/preflight's strict capacity remains available")
        XCTAssertEqual(capacity.availableBytes, 77_540_000_000)
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual(info.capacityText, language == .zhHans
                ? "已用 790.39 GB / 共 994.61 GB" : "790.39 GB used / 994.61 GB total")
            XCTAssertTrue(info.capacityText.contains(ByteFormat.storageString(result.usedVolumeBytes)))
        }
    }

    func testCapacityFallbackWithoutImportantUsageKeepsExistingDisplay() {
        let capacity = StorageCapacitySnapshot(totalBytes: 500_000_000_000, availableBytes: 100_000_000_000)
        XCTAssertEqual(capacity.userUsedBytes, capacity.usedBytes)
        XCTAssertEqual(capacity.userAvailableBytes, capacity.availableBytes)
    }

    func testActivityCapacityReadIncludesTheSameImportantUsageFigureAsSpaceMap() throws {
        let root = SwiftSourceScanning.projectRoot.appendingPathComponent("Sources/StorageCleanerMac")
        let info = try String(contentsOf: root.appendingPathComponent("Features/Activity/MyActivityMacInfo.swift"), encoding: .utf8)
        XCTAssertTrue(info.contains("capacity: StorageCapacityService.snapshot()"))
        XCTAssertFalse(info.contains("includeImportantUsage: false"))
        let disk = try String(contentsOf: root.appendingPathComponent("Services/DiskScanner.swift"), encoding: .utf8)
        XCTAssertTrue(disk.contains("volumeAvailableBytes: capacity?.userAvailableBytes ?? 0"))
        let card = try String(contentsOf: root.appendingPathComponent("Views/CareStudio/CareStudioActivityCards.swift"), encoding: .utf8)
        XCTAssertTrue(card.contains("LightfieldDataBar(progress: capacity.userUsedRatio"))
        XCTAssertFalse(card.contains("progress: capacity.usedRatio"))
        let health = try String(contentsOf: root.appendingPathComponent("Features/Activity/MyActivityHealth.swift"), encoding: .utf8)
        XCTAssertTrue(health.contains("let free = capacity.availableBytes"))
    }
}
