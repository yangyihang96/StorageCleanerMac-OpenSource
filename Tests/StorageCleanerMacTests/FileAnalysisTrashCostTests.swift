import Foundation
import XCTest
@testable import StorageCleanerMac

/// r2-fa-followups P1-1 and P2-4: what the rules cost. Rows and the map's
/// tiles ask `block()` while they draw; the link resolver reads the home
/// folder's Library when an analysis ends. Budgets are for Debug builds; a
/// run on a busy machine that misses one is re-run when idle, never loosened.
final class FileAnalysisTrashCostTests: XCTestCase {
    /// P2-4: a row's check folds only the row's own path, not every
    /// protected name again (2026-10-07 review: 83–291 µs a call in Debug;
    /// 45–150 µs here before the fix, 5–10 µs after).
    func testARowsRuleCheckFoldsOnlyItsOwnPath() {
        let home = "/Users/fixture"
        let policy = FileAnalysisTrashPolicy(rootPath: home, targetKind: .homeDirectory, homePath: home,
                                             appDataPath: home + "/Library/Application Support/StorageCleanerMac",
                                             excludedPaths: [])
        let samples: [(path: String, isDirectory: Bool)] = [
            (home + "/Downloads/archive.zip", false),
            (home + "/Projects/src", true),
            (home + "/Library/Application Support/Vendor/cache", true),
            (home + "/Library/Containers/com.vendor.app/Data/Library/Caches", true),
        ]
        let iterations = 2_000
        for sample in samples {
            let name = (sample.path as NSString).lastPathComponent
            let kind = sample.isDirectory ? "folder" : "file"
            _ = policy.block(path: sample.path, name: name, kind: kind, isDirectory: sample.isDirectory, isEstimated: false)
            let start = ContinuousClock.now
            for _ in 0..<iterations {
                _ = policy.block(path: sample.path, name: name, kind: kind, isDirectory: sample.isDirectory,
                                 isEstimated: false)
            }
            let perCall = (ContinuousClock.now - start) / iterations
            print("P2-4 block() \(sample.path.replacingOccurrences(of: home, with: "~")) per call \(perCall)")
            XCTAssertLessThan(perCall, .microseconds(30), sample.path)
        }
    }

    /// P1-1: the link resolver lists each folder once and folds each name
    /// once; a container's `Data` is one lstat (2026-10-07 review: 2.8 s for
    /// this synthetic home and 4.6–4.9 s for a real one with 1,102
    /// containers, on the main thread). A fixture home only: nothing here
    /// reads the real Library.
    func testTheLinkResolverReadsAThousandContainersWithinBudget() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let home = fixture.base.appendingPathComponent("Home", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        for index in 0..<1_000 {
            try manager.createDirectory(at: library.appendingPathComponent("Containers/com.vendor.app\(index)/Data"),
                                        withIntermediateDirectories: true)
        }
        for index in 0..<250 {
            try manager.createDirectory(at: library.appendingPathComponent("Group Containers/group.com.vendor.app\(index)"),
                                        withIntermediateDirectories: true)
            try manager.createDirectory(at: library.appendingPathComponent("Application Support/Vendor\(index)"),
                                        withIntermediateDirectories: true)
        }
        for name in ["Caches", "Preferences", "Mail", "Logs", "Cookies", "HTTPStorages"] {
            try manager.createDirectory(at: library.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        // One container lives elsewhere through a link: still found, with its Data.
        let elsewhere = fixture.url("Linked/com.linked.tool")
        try manager.createDirectory(at: elsewhere.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: library.appendingPathComponent("Containers/com.linked.tool"),
                                       withDestinationURL: elsewhere)

        var timings: [Duration] = []
        var locations: [FileAnalysisProtectedLocation] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            locations = FileAnalysisProtectedLinkResolver.locations(
                homePath: home.path, appDataPath: home.appendingPathComponent("AppData").path)
            timings.append(ContinuousClock.now - start)
        }
        print("P1-1 resolver, 1,000 containers: \(timings)")
        for timing in timings { XCTAssertLessThan(timing, .milliseconds(200)) }
        let target = elsewhere.resolvingSymlinksInPath().path
        XCTAssertEqual(Set(locations.map(\.path)), [target, target + "/Data"])
        XCTAssertTrue(locations.allSatisfy { $0.block == .appContainer && !$0.protectsContents })
    }

    /// P1-1 on this machine's own home folder, only when asked
    /// (STORAGE_CLEANER_R2FAF_REAL_HOME=1); skipped otherwise. Read-only:
    /// folder names and link metadata, as the app reads them; prints counts
    /// and times, no paths. Same budget as the fixture test.
    func testTheLinkResolverOnThisMachinesHomeWhenAskedTo() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STORAGE_CLEANER_R2FAF_REAL_HOME"] == "1",
                          "Reads the real Library; set STORAGE_CLEANER_R2FAF_REAL_HOME=1 to run it.")
        let home = PathSafety.lexicalHomePath
        func count(_ relative: String) -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: home + "/" + relative))?.count ?? -1
        }
        var timings: [Duration] = []
        var found = 0
        for _ in 0..<3 {
            let start = ContinuousClock.now
            found = FileAnalysisProtectedLinkResolver.locations(
                homePath: home, appDataPath: PathSafety.lexicalPath(AppDataDirectories.applicationSupportRoot.path)).count
            timings.append(ContinuousClock.now - start)
        }
        print("P1-1 resolver, this home: containers=\(count("Library/Containers")) groups=\(count("Library/Group Containers")) "
              + "support=\(count("Library/Application Support")) locations=\(found) timings=\(timings)")
        for timing in timings { XCTAssertLessThan(timing, .milliseconds(200)) }
    }
}
