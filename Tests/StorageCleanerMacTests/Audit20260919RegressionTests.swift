import Foundation
import XCTest
@testable import StorageCleanerMac

final class Audit20260919RegressionTests: XCTestCase {
    func testEvenIdenticalSamplesHaveZeroMAD() throws {
        for count in [2, 4, 8, 24] {
            let result = try BenchmarkStatistics.summarize(Array(repeating: 100, count: count))
            XCTAssertEqual(result.medianAbsoluteDeviation, 0)
            XCTAssertEqual(result.relativeMedianAbsoluteDeviation, 0)
        }
    }

    func testZeroMADWithOutlierIsValid() throws {
        XCTAssertEqual(try BenchmarkStatistics.summarize([100, 100, 100, 150]).medianAbsoluteDeviation, 0)
    }

    func testMeasurementsStillRejectInvalidValues() {
        for values: [Double] in [[], [0], [-1], [.nan], [.infinity], [1, 0]] {
            XCTAssertThrowsError(try BenchmarkStatistics.summarize(values))
        }
        XCTAssertThrowsError(try BenchmarkStatistics.percentile(0.5, samples: [0, 0]))
    }

    func testCandidatePolicyRejectsPathInjection() {
        let home = URL(fileURLWithPath: "/fixture/home", isDirectory: true)
        for value in ["", ".", "..", "../Caches/OtherApp", "/absolute", "a/b", "a\\b", "a\n", "a\0", "a b", "com.示例.app", "a:b", "a%2fb"] {
            XCTAssertTrue(UninstallCandidatePathPolicy.candidateURLs(bundleIdentifier: value, homeDirectory: home).isEmpty)
        }
        XCTAssertTrue(home.isFileURL, "fixture must use a file URL")
        XCTAssertTrue(UninstallCandidatePathPolicy.isSafeComponent("com.example.Tool"), "valid identifier must remain accepted in optimized builds")
        XCTAssertTrue(UninstallCandidatePathPolicy.isSafeComponent("org.Example-2.Tool9"))
        let paths = UninstallCandidatePathPolicy.candidateURLs(bundleIdentifier: "com.example.Tool", homeDirectory: home).map(\.path)
        XCTAssertEqual(paths.count, 4)
        XCTAssertFalse(paths.contains { $0.contains("Group Containers") })
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("/fixture/home/Library/") })
    }

    func testOwnedStagingDirectoryCleansPartiallyCreatedCopy() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: parent) }
        let unrelated = parent.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let staging = try MigrationStagingDirectory(parentURL: parent)
        let partial = staging.url.appendingPathComponent("Example.app", isDirectory: true)
        try fm.createDirectory(at: partial, withIntermediateDirectories: false)
        try Data("partial".utf8).write(to: partial.appendingPathComponent("fragment"))
        try staging.remove()
        XCTAssertFalse(fm.fileExists(atPath: staging.url.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }
}
