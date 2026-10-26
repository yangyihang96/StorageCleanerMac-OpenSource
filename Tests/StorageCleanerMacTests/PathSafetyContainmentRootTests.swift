import Foundation
import XCTest
@testable import StorageCleanerMac

/// D116 (G12): `PathSafety.ContainmentRoot` works out a root's two forms once
/// per walk. It must give the same answers as `isContained` on every path the
/// scanner can meet, and a root relinked mid-walk must not move the boundary.
/// Every path here is inside a fixture made by the test.
final class PathSafetyContainmentRootTests: XCTestCase {
    func testTheCachedRootAnswersLikeTheCheckItReplaces() throws {
        let base = try makeFixture()
        let roots = rootForms(base)
        let candidates = candidateForms(base)
        var compared = 0
        for root in roots {
            let cached = PathSafety.ContainmentRoot(root)
            for candidate in candidates {
                let written = PathSafety.isContained(candidate, in: root, resolvingSymlinks: false)
                let resolved = PathSafety.isContained(candidate, in: root, resolvingSymlinks: true)
                XCTAssertEqual(cached.contains(candidate, resolvingSymlinks: false), written, "\(candidate) in \(root)")
                XCTAssertEqual(cached.contains(candidate, resolvingSymlinks: true), resolved, "\(candidate) in \(root), resolved")
                XCTAssertEqual(cached.containsAsWrittenAndResolved(candidate), written && resolved, "\(candidate) in \(root), both")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 300)

        // The comparison covers each kind of answer, not only "inside".
        let root = PathSafety.ContainmentRoot(base + "/root")
        XCTAssertTrue(root.containsAsWrittenAndResolved(base + "/root/a/b/file"))
        XCTAssertTrue(root.containsAsWrittenAndResolved(base + "/root"))
        XCTAssertFalse(root.contains(base + "/rootX/file", resolvingSymlinks: false), "A shared name prefix is not inside")
        XCTAssertFalse(root.contains(base + "/root/../rootX/file", resolvingSymlinks: false))
        XCTAssertTrue(root.contains(base + "/root/inner-link/x", resolvingSymlinks: false))
        XCTAssertFalse(root.contains(base + "/root/inner-link/x", resolvingSymlinks: true), "A link out of the root resolves outside")
        XCTAssertFalse(root.containsAsWrittenAndResolved(base + "/root/abs-link/x"))
        XCTAssertFalse(root.contains(base + "/root-link/a", resolvingSymlinks: false))
        XCTAssertTrue(root.contains(base + "/root-link/a", resolvingSymlinks: true))
        XCTAssertFalse(root.containsAsWrittenAndResolved(base + "/root-link/a"), "Both checks must pass")
        XCTAssertEqual(root, PathSafety.ContainmentRoot(base + "/root/"))
        XCTAssertEqual(root, PathSafety.ContainmentRoot(base + "/rootX/../root"))
    }

    func testARootRelinkedDuringTheWalkKeepsItsBoundary() throws {
        let base = try makeFixture()
        let moving = base + "/moving"
        try FileManager.default.createDirectory(atPath: moving, withIntermediateDirectories: false)
        let cached = PathSafety.ContainmentRoot(moving)
        XCTAssertTrue(cached.containsAsWrittenAndResolved(moving + "/x"))

        // The root is swapped for a link to another folder after the walk began.
        try FileManager.default.moveItem(atPath: moving, toPath: base + "/moved-away")
        try FileManager.default.createSymbolicLink(atPath: moving, withDestinationPath: base + "/outside")

        XCTAssertTrue(PathSafety.isContained(moving + "/x", in: moving, resolvingSymlinks: true),
                      "Working out the root again follows the new link")
        XCTAssertFalse(cached.contains(moving + "/x", resolvingSymlinks: true))
        XCTAssertFalse(cached.containsAsWrittenAndResolved(moving + "/x"))
        XCTAssertTrue(cached.contains(moving + "/x", resolvingSymlinks: false), "The written form is unchanged")
    }

    func testTheScannerChecksEachWalkAgainstOneCachedRoot() throws {
        let code = SwiftSourceScanning.code(try String(
            contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/ReadOnlyCleanupScanner.swift"),
            encoding: .utf8))
        let compact = SwiftSourceScanning.compact(code)
        XCTAssertFalse(compact.contains("allowedRootPath"))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "PathSafety.ContainmentRoot(", in: compact), 2,
                       "One cached root per rule walk and one for the Trash")
        let body = try SwiftSourceScanning.body(of: "private func aggregateSize(", in: code)
        XCTAssertTrue(SwiftSourceScanning.compact(body).contains("guardallowedRoot.containsAsWrittenAndResolved(snapshot.standardizedPath)else{"))
        XCTAssertFalse(body.contains("PathSafety.isContained"))
    }

    // MARK: - Fixture

    /// base/root/{a/b/file, inner-link -> ../outside, abs-link -> base/outside, self-link -> .},
    /// base/rootX/file, base/outside/x, base/root-link -> root.
    private func makeFixture() throws -> String {
        let url = TestFileSystem.uniqueRoot("ContainmentRoot")
        TestFileSystem.registerCleanup(of: url, for: self)
        let base = url.path
        let manager = FileManager.default
        for folder in ["root/a/b", "rootX", "outside"] {
            try manager.createDirectory(atPath: base + "/" + folder, withIntermediateDirectories: true)
        }
        for file in ["root/a/b/file", "rootX/file", "outside/x"] {
            XCTAssertTrue(manager.createFile(atPath: base + "/" + file, contents: Data([1])))
        }
        try manager.createSymbolicLink(atPath: base + "/root/inner-link", withDestinationPath: "../outside")
        try manager.createSymbolicLink(atPath: base + "/root/abs-link", withDestinationPath: base + "/outside")
        try manager.createSymbolicLink(atPath: base + "/root/self-link", withDestinationPath: ".")
        try manager.createSymbolicLink(atPath: base + "/root-link", withDestinationPath: "root")
        return base
    }

    /// The fixture's own base written both through /var and through /private/var, when it lives there.
    private func baseForms(_ base: String) -> [String] {
        var forms = [base]
        if base.hasPrefix("/private/var/") {
            forms.append(String(base.dropFirst("/private".count)))
        } else if base.hasPrefix("/var/") {
            forms.append("/private" + base)
        }
        return forms
    }

    private func rootForms(_ base: String) -> [String] {
        baseForms(base).flatMap { base in
            ["/root", "/root/", "/./root", "//root", "/rootX/../root", "/root-link", "/root/a", "/root/self-link", "/rootX"]
                .map { base + $0 }
        }
    }

    private func candidateForms(_ base: String) -> [String] {
        baseForms(base).flatMap { base in
            [
                "", "/root", "/root/", "/root/a", "/root/a/b/file", "/root/a/../a/b", "/root/a/./b", "//root//a",
                "/root/../rootX/file", "/rootX", "/rootX/file", "/root/inner-link", "/root/inner-link/x",
                "/root/abs-link/x", "/root/self-link/a", "/root-link", "/root-link/a", "/outside/x",
                "/root/missing/deeper", "/root/a/b/file/",
            ].map { base + $0 }
        }
    }
}
