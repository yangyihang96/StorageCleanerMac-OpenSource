import FanControlShared
import Foundation
import XCTest

/// The helper's caller check builds the installed executable path from these
/// constants. They must equal the names the packaging scripts actually produce.
final class BuildIdentityPackagingTests: XCTestCase {
    func testExecutableNamesAndInstallPathsMatchPackagingScripts() throws {
        let run = try script("script/build_and_run.sh")
        let release = try script("script/make_release_dmg.sh")
        let beta = try section(run, from: "if [ \"$BETA_MODE\" -eq 1 ]; then\n  APP_VERSION=", to: "\nfi\n")

        // Values read from the scripts, compared with both build identities.
        let betaName = try value(of: "APP_NAME", in: beta)
        let betaDisplay = try value(of: "APP_DISPLAY_NAME", in: beta)
        let releaseName = try value(of: "APP_NAME", in: release)
        let releaseDisplay = try value(of: "DISPLAY_NAME", in: release)
        XCTAssertEqual(betaName, "StorageCleanerMacBeta")
        XCTAssertEqual(releaseName, "StorageCleanerMac")
        XCTAssertEqual(StorageCleanerBuildIdentity.executableName(beta: true), betaName)
        XCTAssertEqual(StorageCleanerBuildIdentity.executableName(beta: false), releaseName)
        XCTAssertEqual(StorageCleanerBuildIdentity.installedApplicationPath(beta: true), "/Applications/\(betaDisplay).app")
        XCTAssertEqual(StorageCleanerBuildIdentity.installedApplicationPath(beta: false), "/Applications/\(releaseDisplay).app")
        XCTAssertEqual(StorageCleanerBuildIdentity.installedExecutablePath(beta: true),
                       "/Applications/\(betaDisplay).app/Contents/MacOS/\(betaName)")
        XCTAssertEqual(StorageCleanerBuildIdentity.installedExecutablePath(beta: false),
                       "/Applications/\(releaseDisplay).app/Contents/MacOS/\(releaseName)")
        XCTAssertEqual(StorageCleanerBuildIdentity.installedExecutablePath,
                       StorageCleanerBuildIdentity.installedExecutablePath(beta: StorageCleanerBuildIdentity.isBeta))
        XCTAssertEqual(StorageCleanerBuildIdentity.appExecutableName,
                       StorageCleanerBuildIdentity.executableName(beta: StorageCleanerBuildIdentity.isBeta))

        // The bundles are named after the display names and Info.plist names $APP_NAME as the executable.
        XCTAssertTrue(beta.contains("APP_BUNDLE=\"$DIST_DIR/\(betaDisplay).app\""))
        XCTAssertTrue(release.contains("APP_BUNDLE=\"$BUILD_ROOT/$DISPLAY_NAME.app\""))
        XCTAssertTrue(release.contains("/Applications/\(releaseDisplay).app"))
        for source in [run, release] {
            XCTAssertTrue(source.contains("<key>CFBundleExecutable</key>\n  <string>$APP_NAME</string>"))
        }
        XCTAssertTrue(run.contains("[ \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \"$INFO_PLIST\")\" = \"$APP_NAME\" ]"))

        // The caller policy must use these constants, not its own literal path.
        let policy = try script("Sources/FanControlShared/PowermetricsSample.swift")
        XCTAssertTrue(policy.contains("StorageCleanerBuildIdentity.installedExecutablePath"))
        XCTAssertTrue(policy.contains("StorageCleanerBuildIdentity.installedApplicationPath"))
        XCTAssertFalse(policy.contains("/Contents/MacOS/"))
        XCTAssertFalse(policy.contains("/Applications/"))
    }

    /// `NAME="value"` at the start of a line (shell assignment).
    private func value(of name: String, in source: String) throws -> String {
        let lines = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(name + "=\"") && $0.hasSuffix("\"") }
        XCTAssertEqual(lines.count, 1, name)
        let line = try XCTUnwrap(lines.first, name)
        return String(line.dropFirst(name.count + 2).dropLast())
    }

    private func script(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func section(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start), start)
        let upper = try XCTUnwrap(source.range(of: end, range: lower.upperBound..<source.endIndex), end)
        return String(source[lower.lowerBound..<upper.lowerBound])
    }
}
