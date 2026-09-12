import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppInstallationConflictServiceTests: XCTestCase {
    private let bundleIdentifier = "com.local.StorageCleanerMac"

    func testProductionPathsAreLimitedToTheTwoKnownApplicationNames() {
        XCTAssertEqual(
            AppInstallationConflictService.canonicalApplicationURL.path,
            "/Applications/存储清理助手.app"
        )
        XCTAssertEqual(
            AppInstallationConflictService.legacyApplicationURL.path,
            "/Applications/StorageCleanerMac.app"
        )
    }

    func testDetectsDistinctCopiesWithTheExpectedBundleIdentifier() throws {
        try withTemporaryDirectory { root in
            let canonical = root.appendingPathComponent("存储清理助手.app", isDirectory: true)
            let legacy = root.appendingPathComponent("StorageCleanerMac.app", isDirectory: true)
            try makeApp(at: canonical, version: "1.3.1", build: "202607150900")
            try makeApp(at: legacy, version: "1.3.0", build: "202607150442")

            let conflict = AppInstallationConflictService.detect(
                expectedBundleIdentifier: bundleIdentifier,
                currentBundleURL: canonical,
                canonicalURL: canonical,
                legacyURL: legacy
            )

            XCTAssertEqual(conflict?.canonicalCopy.version, "1.3.1")
            XCTAssertEqual(conflict?.canonicalCopy.build, "202607150900")
            XCTAssertEqual(conflict?.legacyCopy.version, "1.3.0")
            XCTAssertEqual(conflict?.legacyCopy.build, "202607150442")
            XCTAssertEqual(conflict?.currentRuntimePath, canonical.path)
        }
    }

    func testRequiresBothCopiesToMatchTheExpectedBundleIdentifier() throws {
        try withTemporaryDirectory { root in
            let canonical = root.appendingPathComponent("存储清理助手.app", isDirectory: true)
            let legacy = root.appendingPathComponent("StorageCleanerMac.app", isDirectory: true)
            try makeApp(at: canonical, version: "1.3.1", build: "2")
            try makeApp(
                at: legacy,
                bundleIdentifier: "com.example.Unrelated",
                version: "1.3.0",
                build: "1"
            )

            XCTAssertNil(
                AppInstallationConflictService.detect(
                    expectedBundleIdentifier: bundleIdentifier,
                    currentBundleURL: canonical,
                    canonicalURL: canonical,
                    legacyURL: legacy
                )
            )
        }
    }

    func testDoesNotReportTwoPathsThatResolveToTheSameAppResource() throws {
        try withTemporaryDirectory { root in
            let canonical = root.appendingPathComponent("存储清理助手.app", isDirectory: true)
            let legacy = root.appendingPathComponent("StorageCleanerMac.app", isDirectory: true)
            try makeApp(at: canonical, version: "1.3.1", build: "2")
            try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: canonical)

            XCTAssertNil(
                AppInstallationConflictService.detect(
                    expectedBundleIdentifier: bundleIdentifier,
                    currentBundleURL: canonical,
                    canonicalURL: canonical,
                    legacyURL: legacy
                )
            )
        }
    }

    func testMissingOrMalformedCopyDoesNotProduceAConflict() throws {
        try withTemporaryDirectory { root in
            let canonical = root.appendingPathComponent("存储清理助手.app", isDirectory: true)
            let legacy = root.appendingPathComponent("StorageCleanerMac.app", isDirectory: true)
            try makeApp(at: canonical, version: "1.3.1", build: "2")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

            XCTAssertNil(
                AppInstallationConflictService.detect(
                    expectedBundleIdentifier: bundleIdentifier,
                    currentBundleURL: canonical,
                    canonicalURL: canonical,
                    legacyURL: legacy
                )
            )
        }
    }

    @MainActor
    func testControllerDismissesTheSameFingerprintButShowsAChangedCombination() async {
        await withIsolatedDefaults { defaults, key in
            let original = makeConflict(canonicalBuild: "2", legacyBuild: "1")
            let firstController = AppInstallationConflictController(
                defaults: defaults,
                dismissalDefaultsKey: key,
                detector: { original },
                revealInFinder: { _ in }
            )

            await firstController.checkIfNeeded()
            XCTAssertEqual(firstController.conflict, original)
            firstController.dismiss()
            XCTAssertNil(firstController.conflict)
            XCTAssertEqual(defaults.string(forKey: key), original.fingerprint)

            let sameController = AppInstallationConflictController(
                defaults: defaults,
                dismissalDefaultsKey: key,
                detector: { original },
                revealInFinder: { _ in }
            )
            await sameController.checkIfNeeded()
            XCTAssertNil(sameController.conflict)

            let changed = makeConflict(canonicalBuild: "3", legacyBuild: "1")
            let changedController = AppInstallationConflictController(
                defaults: defaults,
                dismissalDefaultsKey: key,
                detector: { changed },
                revealInFinder: { _ in }
            )
            await changedController.checkIfNeeded()
            XCTAssertEqual(changedController.conflict, changed)
        }
    }

    @MainActor
    func testControllerKeepsDismissalWhenAConflictIsTemporarilyUnreadable() async {
        await withIsolatedDefaults { defaults, key in
            defaults.set("stale", forKey: key)
            let controller = AppInstallationConflictController(
                defaults: defaults,
                dismissalDefaultsKey: key,
                detector: { nil },
                revealInFinder: { _ in }
            )

            await controller.checkIfNeeded()
            XCTAssertNil(controller.conflict)
            XCTAssertEqual(defaults.string(forKey: key), "stale")
        }
    }

    @MainActor
    func testControllerOnlyRevealsBothCopiesAfterUserAction() async {
        await withIsolatedDefaults { defaults, key in
            let conflict = makeConflict(canonicalBuild: "2", legacyBuild: "1")
            var revealedURLs: [URL] = []
            let controller = AppInstallationConflictController(
                defaults: defaults,
                dismissalDefaultsKey: key,
                detector: { conflict },
                revealInFinder: { revealedURLs = $0 }
            )

            XCTAssertTrue(revealedURLs.isEmpty)
            await controller.checkIfNeeded()
            XCTAssertTrue(revealedURLs.isEmpty)
            controller.revealCopies()
            XCTAssertEqual(revealedURLs, conflict.copies.map(\.url))
        }
    }

    @MainActor
    func testControllerRunsFilesystemDetectionOffTheMainThread() async {
        let conflict = makeConflict(canonicalBuild: "2", legacyBuild: "1")
        let controller = AppInstallationConflictController(
            detector: { Thread.isMainThread ? nil : conflict },
            revealInFinder: { _ in }
        )

        await controller.checkIfNeeded()

        XCTAssertEqual(controller.conflict, conflict)
    }

    private func makeConflict(canonicalBuild: String, legacyBuild: String) -> AppInstallationConflict {
        AppInstallationConflict(
            canonicalCopy: InstalledAppCopy(
                url: AppInstallationConflictService.canonicalApplicationURL,
                bundleIdentifier: bundleIdentifier,
                version: "1.3.1",
                build: canonicalBuild,
                resourceIdentity: "canonical-\(canonicalBuild)"
            ),
            legacyCopy: InstalledAppCopy(
                url: AppInstallationConflictService.legacyApplicationURL,
                bundleIdentifier: bundleIdentifier,
                version: "1.3.0",
                build: legacyBuild,
                resourceIdentity: "legacy-\(legacyBuild)"
            ),
            currentRuntimePath: AppInstallationConflictService.canonicalApplicationURL.path
        )
    }

    private func makeApp(
        at url: URL,
        bundleIdentifier: String = "com.local.StorageCleanerMac",
        version: String,
        build: String
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppInstallationConflictServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    @MainActor
    private func withIsolatedDefaults(
        _ body: (UserDefaults, String) async -> Void
    ) async {
        let suiteName = "AppInstallationConflictServiceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await body(defaults, "dismissedFingerprint")
    }
}
