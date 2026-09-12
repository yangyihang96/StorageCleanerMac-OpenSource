import XCTest
@testable import StorageCleanerMac

final class OverviewPerformanceRegressionTests: XCTestCase {
    func testOverviewRootDoesNotFeedGeometryHeightBackIntoScrollContent() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/OverviewView.swift")
        let bodySource = try XCTUnwrap(
            source.components(separatedBy: "    var body: some View {").dropFirst().first?
                .components(separatedBy: "    private var resultToolbar: some View {").first
        )

        XCTAssertFalse(bodySource.contains("GeometryReader"))
        XCTAssertFalse(bodySource.contains("proxy.size.height"))
        XCTAssertTrue(bodySource.contains("ScrollView {"))
        XCTAssertTrue(bodySource.contains(".padding(AppDesignTokens.Layout.pagePadding)"))
        XCTAssertFalse(bodySource.contains("AppDesignTokens.Layout.readablePageMaxWidth"))
    }

    func testDecisionByteTotalsNormalizeAvailablePathsOnlyOnce() {
        let items = makeDecisionItems()
        var normalizationCallCount = 0
        let result = ScanResult(
            generatedAt: Date(timeIntervalSince1970: 100),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: items,
            deniedPaths: [],
            decisionPathNormalizer: { path in
                normalizationCallCount += 1
                return PathSafety.lexicalPath(path)
            }
        )

        XCTAssertEqual(normalizationCallCount, items.filter { $0.status == .available }.count)

        for _ in 0..<200 {
            XCTAssertEqual(result.greenBytes, 200)
            XCTAssertEqual(result.yellowBytes, 750)
            XCTAssertEqual(result.redBytes, 50)
            XCTAssertEqual(result.bytes(for: .other), 100)
            XCTAssertEqual(result.identifiedDecisionBytes, 1_000)
        }

        XCTAssertEqual(normalizationCallCount, items.filter { $0.status == .available }.count)
    }

    func testDecisionByteTotalsRefreshWhenItemsMutate() throws {
        var result = ScanResult(
            generatedAt: Date(timeIntervalSince1970: 100),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: makeDecisionItems(),
            deniedPaths: []
        )

        let greenIndex = try XCTUnwrap(result.items.firstIndex { $0.id == "green-child" })
        result.items[greenIndex].status = .movedToTrash

        XCTAssertEqual(result.greenBytes, 0)
        XCTAssertEqual(result.yellowBytes, 950)
        XCTAssertEqual(result.redBytes, 50)

        result.items.append(
            makeItem(
                id: "new-green",
                sourceID: "dev_caches",
                path: "/tmp/elsewhere/.cache",
                bytes: 100,
                tier: .green
            )
        )

        XCTAssertEqual(result.greenBytes, 100)
        XCTAssertEqual(result.identifiedDecisionBytes, 1_100)
    }

    func testDecisionPathCacheIsReusedAcrossStatusUpdates() throws {
        let items = makeDecisionItems()
        var normalizationCallCount = 0
        var result = ScanResult(
            generatedAt: Date(timeIntervalSince1970: 100),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: items,
            deniedPaths: [],
            decisionPathNormalizer: { path in
                normalizationCallCount += 1
                return PathSafety.lexicalPath(path)
            }
        )
        let initialCallCount = normalizationCallCount

        result.markMovedToTrash(itemIDs: ["green-child", "red-child"])

        XCTAssertEqual(normalizationCallCount, initialCallCount)
        XCTAssertEqual(result.greenBytes, 0)
        XCTAssertEqual(result.redBytes, 0)
    }

    func testCleanupProjectionBatchesMovedStatusUpdate() throws {
        let serviceSource = try sourceText(at: "Sources/StorageCleanerMac/Services/ScanHistoryService.swift")
        let projectionSource = try XCTUnwrap(
            serviceSource.components(separatedBy: "    static func cleanupProjection(for result: ScanResult)").dropFirst().first?
                .components(separatedBy: "    static func cleanupFollowUp(for result: ScanResult)").first
        )

        XCTAssertTrue(projectionSource.contains("markMovedToTrash(itemIDs:"))
        XCTAssertFalse(projectionSource.contains("for item in candidates"))
    }

    func testDecisionByteCachePreservesResolvedSymlinkOverlap() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let realDirectory = temporaryDirectory.appendingPathComponent("real", isDirectory: true)
        let aliasDirectory = temporaryDirectory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: realDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let result = ScanResult(
            generatedAt: Date(timeIntervalSince1970: 100),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [
                makeItem(
                    id: "large-alias",
                    sourceID: "large_files",
                    path: aliasDirectory.path,
                    bytes: 1_000,
                    tier: .yellow
                ),
                makeItem(
                    id: "green-real-child",
                    sourceID: "dev_caches",
                    path: realDirectory.appendingPathComponent(".build", isDirectory: true).path,
                    bytes: 200,
                    tier: .green
                )
            ],
            deniedPaths: []
        )

        XCTAssertEqual(result.greenBytes, 200)
        XCTAssertEqual(result.yellowBytes, 800)
        XCTAssertEqual(result.identifiedDecisionBytes, 1_000)
    }

    private func makeDecisionItems() -> [StorageItem] {
        [
            makeItem(
                id: "large-parent",
                sourceID: "large_files",
                path: "/tmp/project",
                bytes: 1_000,
                tier: .yellow
            ),
            makeItem(
                id: "green-child",
                sourceID: "dev_caches",
                path: "/tmp/project/.build",
                bytes: 200,
                tier: .green
            ),
            makeItem(
                id: "yellow-child",
                sourceID: "codex_installers",
                path: "/tmp/project/release",
                bytes: 400,
                tier: .yellow
            ),
            makeItem(
                id: "red-child",
                sourceID: "applications",
                path: "/tmp/project/Critical.app",
                bytes: 50,
                tier: .red
            ),
            makeItem(
                id: "other-item",
                sourceID: "other",
                path: "/tmp/other",
                bytes: 100,
                tier: .other
            ),
            makeItem(
                id: "removed-item",
                sourceID: "dev_caches",
                path: "/tmp/removed",
                bytes: 300,
                tier: .green,
                status: .movedToTrash
            )
        ]
    }

    private func makeItem(
        id: String,
        sourceID: String,
        path: String,
        bytes: Int64,
        tier: StorageTier,
        status: ItemStatus = .available
    ) -> StorageItem {
        StorageItem(
            id: id,
            title: id,
            path: path,
            sourceID: sourceID,
            groupTitle: sourceID,
            sizeBytes: bytes,
            tier: tier,
            kind: sourceID,
            reason: "",
            recommendation: "",
            risk: "",
            requiresClose: "",
            trashPaths: [],
            openPath: path,
            isDirectory: true,
            status: status
        )
    }

    private func makeSnapshot() -> SystemSnapshot {
        SystemSnapshot(
            osName: "macOS",
            build: "test",
            arch: "arm64",
            user: "tester",
            home: "/Users/tester",
            filesystem: "APFS",
            purgeable: "",
            diskName: "Macintosh HD",
            diskTotalBytes: 2_000,
            diskUsedBytes: 1_200,
            diskFreeBytes: 800
        )
    }

    private func sourceText(at relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
