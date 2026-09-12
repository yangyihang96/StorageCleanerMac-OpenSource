import Foundation
import XCTest

final class AppUpdaterPolicyTests: XCTestCase {
    func testSelfUpdaterPreservesSparklesHighestCompatibleSelection() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Services/AppUpdater.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("updaterDelegate: nil"))
        XCTAssertFalse(source.contains("bestValidUpdate(in appcast:"))
        XCTAssertFalse(source.contains("LatestCompatibleUpdateSelector"))
    }
}
