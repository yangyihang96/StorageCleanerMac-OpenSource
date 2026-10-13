import Foundation
import XCTest

/// Source isolation also runs in the Release test configuration.
final class FeatureLightfieldReleaseIsolationTests: XCTestCase {
    func testResultAndDemoFixturesHaveStrictDebugGuards() throws {
        for name in ["FeatureLightfieldResultFixture.swift", "FeaturePresentationDemo.swift", "LightfieldPerformanceFixture.swift",
                     "FeatureLightfieldFileResultFixture.swift", "FeatureLightfieldApplicationsFixture.swift",
                     "BrowserPrivacyPreviewFixture.swift", "BrowserPrivacyRenderProbe.swift"] {
            let value = try source("Sources/StorageCleanerMac/Debug/" + name)
            XCTAssertTrue(value.hasPrefix("#if DEBUG\n"), name)
            XCTAssertTrue(value.hasSuffix("#endif\n"), name)
            XCTAssertFalse(value.contains("#if DEBUG || STORAGE_CLEANER_BETA"), name)
        }
        let pipeline = try source("Sources/StorageCleanerMac/Debug/MainWindowSnapshotPipeline.swift")
        let marker = try XCTUnwrap(pipeline.range(of: "static func captureFeatureTemplates"))
        let before = pipeline[..<marker.lowerBound]
        XCTAssertGreaterThan(try XCTUnwrap(before.range(of: "#if DEBUG", options: .backwards)).lowerBound,
            try XCTUnwrap(before.range(of: "#endif", options: .backwards)).lowerBound)
    }
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
