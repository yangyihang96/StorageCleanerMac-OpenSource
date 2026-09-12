import XCTest
@testable import StorageCleanerMac

final class ScanModeTests: XCTestCase {
    func testScanModeHasSingleStandardScope() {
        XCTAssertEqual(ScanMode.fallback, .standard)
        XCTAssertEqual(ScanMode.allCases.map(\.rawValue), ["standard"])
        XCTAssertEqual(ScanMode.standard.title, L10n.text("标准", "Standard"))
        XCTAssertEqual(ScanMode.standard.maxScanSeconds, 28)
        XCTAssertEqual(ScanMode.standard.maxChildrenPerDirectory, 36)
        XCTAssertEqual(ScanMode.standard.knownPathLimitMultiplier, 1)
    }

    func testScanResultDefaultsToStandardMode() {
        let result = ScanResult(
            generatedAt: Date(timeIntervalSince1970: 100),
            scanSeconds: 0.1,
            system: makeSnapshot(),
            groups: [],
            items: [],
            deniedPaths: []
        )

        XCTAssertEqual(result.scanMode, .standard)
    }

    func testStandardModeDefinesTheOnlyPlannedGroups() {
        let groups = DiskScanner.plannedPrimaryGroupIDs(for: .standard)

        XCTAssertEqual(groups, ["caches", "logs", "downloads", "applications"])
        XCTAssertEqual(
            DiskScanner.plannedSupplementaryGroupIDs(for: .standard),
            [
                "browser_caches",
                "mail_attachments",
                "codex_intermediates",
                "codex_runtime_records",
                "codex_installers",
                "large_files",
                "duplicate_files",
                "dev_caches"
            ]
        )
        XCTAssertEqual(DiskScanner.plannedLargeFileRoots(for: .standard, homePath: "/Users/tester"), ["/Users/tester/Downloads", "/Users/tester/Desktop", "/Users/tester/Documents"])
        XCTAssertFalse(ScanMode.standard.includesSupplementaryGroup("privacy_traces"))
        XCTAssertEqual(ScanMode.standard.largeFileResultLimit, 80)
    }

    func testPrimaryInterfaceUsesOneScanEntryWithoutModePicker() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"),
            encoding: .utf8
        )
        let storeSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(contentSource.contains("ScanModePicker"))
        XCTAssertFalse(contentSource.contains("Picker(L10n.text(\"扫描模式\", \"Scan Mode\")"))
        XCTAssertFalse(storeSource.contains("scanModeDefaultsKey"))
        XCTAssertFalse(storeSource.contains("@Published var selectedScanMode"))
        XCTAssertTrue(storeSource.contains("private var currentScanMode: ScanMode"))
        XCTAssertTrue(storeSource.contains(".fallback"))
        XCTAssertFalse(contentSource.contains(".quick"))
        XCTAssertFalse(contentSource.contains(".deep"))
    }

    private func makeSnapshot() -> SystemSnapshot {
        SystemSnapshot(
            osName: "macOS",
            build: "test",
            arch: "arm64",
            user: "tester",
            home: NSHomeDirectory(),
            filesystem: "APFS",
            purgeable: "",
            diskName: "Macintosh HD",
            diskTotalBytes: 1_000,
            diskUsedBytes: 500,
            diskFreeBytes: 500
        )
    }
}
