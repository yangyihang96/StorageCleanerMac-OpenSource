import Foundation
import XCTest

/// D48 and AGENTS.md: the app never deletes anything in ~/Library/Preferences.
/// Leftovers there (test suites, old Sparkle probe domains) are moved to the
/// Trash by the main session; cleanup inside the app stays an explicit action
/// on screen that goes to the Trash. Any app source file that knows about the
/// Preferences folder must not call a permanent-deletion primitive.
final class PreferencesFolderContractTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testAppCodeNeverDeletesInsideThePreferencesFolder() throws {
        let sources = projectRoot.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var filesThatKnowThePreferencesFolder: [String] = []
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = Self.code(of: try String(contentsOf: url, encoding: .utf8))
            guard Self.mentionsPreferencesFolder(code) else { continue }
            let relativePath = String(url.path.dropFirst(projectRoot.path.count + 1))
            filesThatKnowThePreferencesFolder.append(relativePath)
            if Self.deletesPermanently(code) {
                offenders.append(relativePath)
            }
        }
        // The uninstall policy and presentation name the folder; the check
        // must see them, or it would pass by finding nothing.
        XCTAssertTrue(
            filesThatKnowThePreferencesFolder.contains("Sources/StorageCleanerMac/Support/UninstallCandidatePathPolicy.swift"),
            "Found: \(filesThatKnowThePreferencesFolder.sorted())"
        )
        XCTAssertEqual(offenders.sorted(), [], "These files name the user preference folder and delete permanently")
    }

    func testTheCheckRecognisesDeletionNextToThePreferencesFolder() {
        let offending = """
        let folder = home.appendingPathComponent("Library/Preferences")
        _ = unlinkat(descriptor, name, 0)
        """
        XCTAssertTrue(Self.mentionsPreferencesFolder(Self.code(of: offending)))
        XCTAssertTrue(Self.deletesPermanently(Self.code(of: offending)))
        XCTAssertTrue(Self.deletesPermanently("try FileManager.default.removeItem(at: url)"))
        XCTAssertTrue(Self.deletesPermanently("unlink(path)"))
        // Comments do not count, and moving to the Trash is not deletion.
        XCTAssertFalse(Self.mentionsPreferencesFolder(Self.code(of: "// Library/Preferences\nlet x = 1")))
        XCTAssertFalse(Self.deletesPermanently("try FileManager.default.trashItem(at: url, resultingItemURL: nil)"))
    }

    /// The source without `//` comments and `/* */` blocks.
    private static func code(of source: String) -> String {
        let withoutBlocks = source.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/"#,
            with: "",
            options: .regularExpression
        )
        return withoutBlocks
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func mentionsPreferencesFolder(_ code: String) -> Bool {
        code.range(of: #"Library/Preferences|"Preferences"|/Preferences/"#, options: .regularExpression) != nil
    }

    private static func deletesPermanently(_ code: String) -> Bool {
        code.range(
            of: #"\bunlink(at)?\s*\(|\bremovefile\s*\(|\brmdir\s*\(|\bremoveItem\s*\("#,
            options: .regularExpression
        ) != nil
    }
}
