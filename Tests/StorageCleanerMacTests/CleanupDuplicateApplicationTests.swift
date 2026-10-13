import Foundation
import XCTest
@testable import StorageCleanerMac

/// P2-1 (D25): copies of an app are duplicates only when bundle identifier,
/// version and build all match. The copy kept is the running one, then the
/// one `xcode-select` points at, then one directly in /Applications, then the
/// newest. Fixtures live in temporary folders only.
final class CleanupDuplicateApplicationTests: XCTestCase {
    /// Xcode.app and Xcode-27.0.0-Beta.app share an identifier but are
    /// different releases: neither is listed, and neither is measured.
    func testCopiesOfDifferentReleasesAreNotDuplicatesAndAreNotMeasured() async throws {
        let fixture = try makeFixture()
        try makeApplication("Xcode.app", in: fixture, identifier: "com.apple.dt.Xcode", version: "26.0", build: "17A100")
        try makeApplication("Xcode-27.0.0-Beta.app", in: fixture, identifier: "com.apple.dt.Xcode", version: "27.0", build: "18A5")
        try makeApplication("Tool.app", in: fixture, identifier: "com.example.tool", version: "1.0", build: "100")
        try makeApplication("Tool copy.app", in: fixture, identifier: "com.example.tool", version: "1.0", build: "100")
        try makeApplication("Tool nightly.app", in: fixture, identifier: "com.example.tool", version: "1.0", build: "101")
        let fileSystem = ListingRecorderFileSystem()

        let session = try await scan(fixture, fileSystem: fileSystem)

        XCTAssertEqual(
            Set(session.candidates.map(\.sourceURL.lastPathComponent)),
            ["Tool.app", "Tool copy.app"]
        )
        for candidate in session.candidates {
            XCTAssertTrue(candidate.recommendation.evidenceCodes.contains("app-short-version:1.0"))
            XCTAssertTrue(candidate.recommendation.evidenceCodes.contains("app-build:100"))
            let summary = try XCTUnwrap(candidate.applicationVersionSummary)
            XCTAssertTrue(summary.contains("1.0") && summary.contains("100"), summary)
        }
        let listed = fileSystem.listedPaths()
        for name in ["Xcode.app", "Xcode-27.0.0-Beta.app", "Tool nightly.app"] {
            let bundle = PathSafety.lexicalPath(fixture.applications.appendingPathComponent(name).path)
            XCTAssertFalse(
                listed.contains { $0 == bundle || $0.hasPrefix(bundle + "/") },
                "\(name) is not a duplicate and must not be traversed"
            )
        }
    }

    /// The copy `xcode-select` points at stays, even when another copy of
    /// the same release is newer.
    func testTheActiveDeveloperDirectoryCopyIsKept() async throws {
        let fixture = try makeFixture()
        let beta = try makeApplication("Xcode-27.0.0-Beta.app", in: fixture, identifier: "com.apple.dt.Xcode", version: "27.0", build: "18A5")
        let plain = try makeApplication("Xcode.app", in: fixture, identifier: "com.apple.dt.Xcode", version: "27.0", build: "18A5")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 86_400)],
            ofItemAtPath: beta.path
        )
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: plain.path)
        let link = fixture.root.appendingPathComponent("xcode_select_link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: beta.appendingPathComponent("Contents/Developer").path
        )

        let session = try await scan(fixture, developerDirectoryLink: link)

        let copies = session.candidates
        XCTAssertEqual(copies.count, 2)
        let keeper = try XCTUnwrap(DuplicateApplicationRetentionPolicy.keeper(among: copies))
        XCTAssertEqual(keeper.sourceURL.lastPathComponent, "Xcode-27.0.0-Beta.app")
        XCTAssertTrue(keeper.recommendation.evidenceCodes.contains("active-developer-directory"))
        var selection = CleanupSelection()
        selection.setCandidates(copies.map(\.id), selected: true, in: session)
        XCTAssertEqual(
            session.candidates.filter { selection.selectedCandidateIDs.contains($0.id) }
                .map(\.sourceURL.lastPathComponent),
            ["Xcode.app"]
        )
    }

    /// Running first, then the active developer directory, then a copy
    /// directly in /Applications, then the newest.
    func testKeeperOrder() {
        let newestNested = copy("/Applications/Tools/App.app", modified: 50)
        let olderRoot = copy("/Applications/App.app", modified: 10)
        XCTAssertEqual(
            DuplicateApplicationRetentionPolicy.keeper(among: [newestNested, olderRoot])?.id,
            olderRoot.id
        )
        let developer = copy("/Applications/Tools/Xcode.app", modified: 1, evidence: ["active-developer-directory"])
        XCTAssertEqual(
            DuplicateApplicationRetentionPolicy.keeper(among: [newestNested, olderRoot, developer])?.id,
            developer.id
        )
        let running = copy("/Applications/Tools/Old.app", modified: 0, running: true)
        XCTAssertEqual(
            DuplicateApplicationRetentionPolicy.keeper(among: [newestNested, olderRoot, developer, running])?.id,
            running.id
        )
        let newerRoot = copy("/Applications/App 2.app", modified: 20)
        XCTAssertEqual(
            DuplicateApplicationRetentionPolicy.keeper(among: [olderRoot, newerRoot])?.id,
            newerRoot.id
        )
    }

    /// P2-7 (round 3): the running copy and the copy the command line tools
    /// use are both kept when they differ; only other copies can be selected,
    /// one at a time or as a group, and a plan drops protected copies too.
    func testRunningAndCommandLineToolsCopiesAreBothKept() throws {
        let sessionID = ScanSessionID()
        let running = copy("/Applications/Xcode.app", modified: 10, running: true, sessionID: sessionID)
        let developer = copy(
            "/Applications/Xcode-beta.app",
            modified: 5,
            evidence: ["active-developer-directory"],
            sessionID: sessionID
        )
        let spare = copy("/Applications/Xcode copy.app", modified: 20, sessionID: sessionID)
        let session = session(sessionID, [running, developer, spare])

        var group = CleanupSelection()
        group.setCandidates([running.id, developer.id, spare.id], selected: true, in: session)
        XCTAssertEqual(group.selectedCandidateIDs, [spare.id])
        var single = CleanupSelection()
        single.setCandidate(developer.id, selected: true, in: session)
        single.setCandidate(running.id, selected: true, in: session)
        XCTAssertEqual(single.selectedCandidateIDs, [], "Protected copies cannot be selected")
        XCTAssertEqual(
            DuplicateApplicationRetentionPolicy.selectableTargets([running.id, developer.id, spare.id], in: session),
            [spare.id]
        )
    }

    /// P2-7 (round 3): two copies, one running and the other used by the
    /// command line tools: nothing can be removed, so the group is not
    /// listed and is counted.
    func testAGroupWhoseCopiesAreAllInUseIsNotListed() async throws {
        let fixture = try makeFixture()
        let beta = try makeApplication("Xcode-27.0.0-Beta.app", in: fixture, identifier: "com.apple.dt.Xcode", version: "27.0", build: "18A5")
        let plain = try makeApplication("Xcode.app", in: fixture, identifier: "com.apple.dt.Xcode", version: "27.0", build: "18A5")
        let link = fixture.root.appendingPathComponent("xcode_select_link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: beta.appendingPathComponent("Contents/Developer").path
        )

        let session = try await scan(
            fixture,
            developerDirectoryLink: link,
            environment: RunningBundleEnvironment(paths: [PathSafety.lexicalPath(plain.path)])
        )

        XCTAssertEqual(session.candidates.map(\.sourceURL.lastPathComponent), [])
        XCTAssertEqual(session.metrics.notActionableCandidateCount, 2)
    }

    /// P2-7 (round 3): the Chinese interface names the copy as the Xcode the
    /// command line tools use, not by the English command name.
    func testTheKeptCopyIsDescribedWithoutTheCommandName() throws {
        let views = try source("Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        XCTAssertTrue(views.contains("命令行工具当前使用的 Xcode"))
        XCTAssertFalse(views.contains("xcode-select 当前使用"))
        let scanner = try source("Sources/StorageCleanerMac/Services/ReadOnlyCleanupScanner.swift")
        XCTAssertFalse(scanner.contains("xcode-select 当前使用"))
    }

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let home: URL
        let applications: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerDuplicateApps-\(UUID().uuidString)")
        let home = root.appendingPathComponent("Home")
        let applications = root.appendingPathComponent("Applications")
        for directory in [home, applications] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, home: home, applications: applications)
    }

    @discardableResult
    private func makeApplication(
        _ name: String,
        in fixture: Fixture,
        identifier: String,
        version: String,
        build: String
    ) throws -> URL {
        let url = fixture.applications.appendingPathComponent(name)
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Resources"),
            withIntermediateDirectories: true
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": identifier,
                "CFBundleName": url.deletingPathExtension().lastPathComponent,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
            ],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 0x5A, count: 8_192)
            .write(to: contents.appendingPathComponent("Resources/payload.bin"))
        return url
    }

    private func scan(
        _ fixture: Fixture,
        fileSystem: any ReadOnlyFileSystem = ListingRecorderFileSystem(),
        developerDirectoryLink: URL? = nil,
        environment: any CleanupApplicationEnvironment = NoCleanupApplicationEnvironment()
    ) async throws -> ScanSession {
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rule = try XCTUnwrap(bundled.rules.first { $0.id == "applications.duplicate-installed-apps" })
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: [lowered(rule)]
        )
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: fileSystem,
            ruleSet: rules,
            applicationsURL: fixture.applications,
            applicationEnvironment: environment,
            developerDirectoryLinkURL: developerDirectoryLink
                ?? fixture.root.appendingPathComponent("no-xcode-select-link")
        )
        return try await scanner.scan(request: CleanupScanRequest(userHomeURL: fixture.home)) { _ in }
    }

    /// Fixture apps are small, so the 100 MiB group threshold drops to 0.
    private func lowered(_ rule: CleanupRule) -> CleanupRule {
        CleanupRule(
            id: rule.id,
            selectionPolicyVersion: rule.selectionPolicyVersion,
            categoryID: rule.categoryID,
            categoryTitleKey: rule.categoryTitleKey,
            titleKey: rule.titleKey,
            root: rule.root,
            candidateScope: rule.candidateScope,
            maximumDepth: rule.maximumDepth,
            minimumAgeDays: rule.minimumAgeDays,
            minimumBytes: 0,
            include: rule.include,
            exclude: rule.exclude,
            cloudPolicy: rule.cloudPolicy,
            risk: rule.risk,
            recommendation: rule.recommendation,
            defaultSelection: rule.defaultSelection,
            executionEligibility: rule.executionEligibility,
            measurementRequirement: rule.measurementRequirement,
            allowsManualSelection: rule.allowsManualSelection,
            action: rule.action,
            requiredClosedBundleIDs: rule.requiredClosedBundleIDs,
            reasonKey: rule.reasonKey,
            ownerDisplayName: rule.ownerDisplayName,
            developerTool: rule.developerTool,
            developerArtifactKind: rule.developerArtifactKind,
            includedBundleIdentifiers: rule.includedBundleIdentifiers,
            requiresDuplicateBundleIdentifier: rule.requiresDuplicateBundleIdentifier,
            ownerInference: rule.ownerInference
        )
    }

    private func session(_ id: ScanSessionID, _ candidates: [ScanCandidate]) -> ScanSession {
        ScanSession(
            id: id,
            rulesVersion: "duplicates.fixture",
            startedAt: Date(),
            completedAt: Date(),
            outcome: .complete,
            categories: [CleanupScanCategory(
                id: "applications",
                title: "Apps",
                subcategories: [CleanupScanSubcategory(
                    id: "applications.duplicate-installed-apps",
                    title: "Duplicates",
                    risk: .protected,
                    recommendation: .notRecommended,
                    reason: "r",
                    candidates: candidates
                )]
            )],
            issues: [],
            permissions: [],
            metrics: ScanMetrics(
                visitedEntryCount: candidates.count,
                candidateCount: candidates.count,
                deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: 0,
                duration: 0
            )
        )
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func copy(
        _ path: String,
        modified: Int64,
        running: Bool = false,
        evidence: [String] = [],
        sessionID: ScanSessionID = ScanSessionID()
    ) -> ScanCandidate {
        var candidate = ScanCandidate(
            id: ScanCandidateID(),
            sessionID: sessionID,
            ruleID: "applications.duplicate-installed-apps",
            ruleSelectionPolicyVersion: 1,
            categoryID: "applications",
            categoryTitle: "Apps",
            subcategoryTitle: "Duplicates",
            sourceURL: URL(fileURLWithPath: path),
            allowedRootURL: URL(fileURLWithPath: "/Applications"),
            snapshot: FileSnapshot(
                identity: FileIdentity(
                    deviceID: 1,
                    inode: UInt64(abs(path.hashValue) % 1_000_000),
                    entryKind: .directory,
                    creationTimeNanoseconds: 1
                ),
                standardizedPath: path,
                volumeIdentifier: "v",
                logicalSizeBytes: 1,
                allocatedSizeBytes: 1,
                modificationTimeNanoseconds: modified,
                isWritableVolume: true,
                isCloudItem: false,
                isCloudPlaceholder: false,
                hasSymbolicLinkComponent: false
            ),
            risk: .protected,
            recommendation: CleanupRecommendation(
                level: .notRecommended,
                reasonCode: "r",
                evidenceCodes: ["duplicate-bundle-group:g"] + evidence
            ),
            defaultSelection: .unselected,
            executionEligibility: .eligibleAfterProtectedReview,
            measurementCompleteness: .complete,
            isManuallySelectable: true,
            action: .moveToTrashAfterProtectedReview,
            requiredClosedBundleIDs: [],
            reason: "r"
        )
        candidate.ownerResolution = .applicationBundle
        candidate.ownerBundleIdentifiers = ["com.example.app"]
        candidate.runningOwnerBundleIdentifiers = running ? ["com.example.app"] : []
        return candidate
    }
}

private struct RunningBundleEnvironment: CleanupApplicationEnvironment {
    let paths: Set<String>

    func snapshot(checkingInstalled _: Set<String>) async -> CleanupApplicationSnapshot {
        CleanupApplicationSnapshot(runningBundlePaths: paths)
    }
}

/// Records every folder listing; ancestor links of the temporary folder are
/// ignored like in the other cleanup fixtures.
private final class ListingRecorderFileSystem: ReadOnlyFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var listed = [String]()

    func listedPaths() -> [String] { lock.withLock { listed } }

    func snapshot(at url: URL) throws -> FileSnapshot {
        let snapshot = try FoundationReadOnlyFileSystem().snapshot(at: url)
        return FileSnapshot(
            identity: snapshot.identity,
            standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier,
            logicalSizeBytes: snapshot.logicalSizeBytes,
            allocatedSizeBytes: snapshot.allocatedSizeBytes,
            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: snapshot.isWritableVolume,
            isCloudItem: snapshot.isCloudItem,
            isCloudPlaceholder: snapshot.isCloudPlaceholder,
            hasSymbolicLinkComponent: false
        )
    }

    func children(of directory: URL) throws -> [URL] {
        lock.withLock { listed.append(PathSafety.lexicalPath(directory.path)) }
        return try FoundationReadOnlyFileSystem().children(of: directory)
    }
}
