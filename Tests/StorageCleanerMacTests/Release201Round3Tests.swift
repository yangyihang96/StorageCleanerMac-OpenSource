import XCTest
@testable import StorageCleanerMac

/// 2.0.1 third round (D97): the items left open after the second runtime
/// review — one byte unit on the migration page and the helper handover after
/// a Beta install.
final class Release201Round3Tests: XCTestCase {
    /// The destination row showed a volume's free space in decimal units
    /// (“321.28 GB”) while its menu listed the same volume in binary units
    /// (“299.2 GiB”); the scan progress used binary units while the results
    /// use decimal ones. The migration flow now writes sizes one way, like
    /// file analysis (D93). The large-file threshold keeps its binary titles,
    /// written out per D85.
    func testMigrationPageWritesSizesInOneUnit() throws {
        let view = try source("Sources/StorageCleanerMac/Views/LargeFilesView.swift")
        let destination = try r2SourceDeclaration("private var migrationDestinationControl", in: view)
        XCTAssertFalse(destination.contains("ByteFormat.string("), "Menu items and the row share one unit")
        XCTAssertEqual(destination.components(separatedBy: "ByteFormat.storageString(").count - 1, 2)
        let metrics = try r2SourceDeclaration("private var runtimeMetrics", in: view)
        let migration = try XCTUnwrap(metrics.range(of: "guard let progress = workspace.storageAnalysisProgress")
            .map { String(metrics[..<$0.lowerBound]) })
        XCTAssertTrue(migration.contains("ByteFormat.storageString(progress.discoveredBytes)"))
        XCTAssertFalse(migration.contains("ByteFormat.string("))
        let results = try source("Sources/StorageCleanerMac/Views/FilesLightfield/FileMigrationLightfieldView.swift")
        XCTAssertFalse(results.contains("ByteFormat.string("), "The migration results already use decimal units")
    }

    /// The old helper only leaves 15 s after its last client quits, and the
    /// new Beta used to reconnect about 3 s after the old one quit, so every
    /// install left the old process running. The install waits (read-only,
    /// bounded) between quitting the old Beta and opening the new one.
    func testBetaInstallWaitsForTheOldHelperBeforeOpeningTheNewBeta() throws {
        let script = try source("script/build_and_run.sh")
        let install = try r2SourceDeclaration("install_beta() ", in: script)
        let quit = try XCTUnwrap(install.range(of: "quit_existing_beta_safely \"$target\"\n"))
        let wait = try XCTUnwrap(install.range(of:
            "python3 \"$ROOT_DIR/script/helper_upgrade_status.py\" wait-exit \"$FAN_HELPER_LABEL\" 30 || true"))
        let open = try XCTUnwrap(install.range(of: "/usr/bin/open -n \"$target\""))
        XCTAssertLessThan(quit.lowerBound, wait.lowerBound)
        XCTAssertLessThan(wait.lowerBound, open.lowerBound)
        // The comments already say none of these run; the commands must agree.
        let commands = install.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        XCTAssertFalse(commands.contains("kickstart"))
        XCTAssertFalse(commands.contains("bootout"))
        XCTAssertFalse(commands.contains("sudo "))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
