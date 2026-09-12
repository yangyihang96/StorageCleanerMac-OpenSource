import Foundation
import XCTest
@testable import StorageCleanerMac

final class CodexArtifactScannerTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexArtifactScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        try super.tearDownWithError()
    }

    func testScannerFindsCodexTemporaryScreenshotsRuntimeRecordsAndInstallers() throws {
        let codex = sandbox.appendingPathComponent(".codex", isDirectory: true)
        let codexTemporary = codex.appendingPathComponent(".tmp", isDirectory: true)
        let generatedImages = codex.appendingPathComponent("generated_images", isDirectory: true)
        let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
        let workspace = sandbox.appendingPathComponent("Documents", isDirectory: true)
        let project = workspace.appendingPathComponent("Project", isDirectory: true)
        let playwright = project.appendingPathComponent(".playwright-mcp", isDirectory: true)
        let ordinaryScreenshots = workspace.appendingPathComponent("screenshots", isDirectory: true)
        let release = project.appendingPathComponent("release", isDirectory: true)
        let functionCheck = release.appendingPathComponent("function-check", isDirectory: true)
        let distApp = project.appendingPathComponent("dist/Project.app/Contents", isDirectory: true)
        let systemTemporary = sandbox.appendingPathComponent("private-tmp", isDirectory: true)
        let temporaryBuild = systemTemporary.appendingPathComponent("storage-cleaner-build", isDirectory: true)

        for directory in [codexTemporary, generatedImages, sessions, playwright, ordinaryScreenshots, functionCheck, distApp, temporaryBuild] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try write(bytes: 2_000_000, to: codexTemporary.appendingPathComponent("plugin-cache.bin"))
        try write(bytes: 300_000, to: generatedImages.appendingPathComponent("exec-screenshot.png"))
        try write(bytes: 3_000_000, to: sessions.appendingPathComponent("session.jsonl"))
        let pageRecord = playwright.appendingPathComponent("page-2026-07-13.yml")
        let consoleRecord = playwright.appendingPathComponent("console-2026-07-13.log")
        let fixedPageRecord = playwright.appendingPathComponent("page.yml")
        let fixedTraceRecord = playwright.appendingPathComponent("trace.zip")
        let screenshot = playwright.appendingPathComponent("screen.png")
        let generatedInstaller = playwright.appendingPathComponent("Project.dmg")
        let downloadedInstaller = playwright.appendingPathComponent("WeCom-5-0-9-99905-Apple.dmg")
        try write(bytes: 120_000, to: pageRecord)
        try write(bytes: 80_000, to: consoleRecord)
        try write(bytes: 70_000, to: fixedPageRecord)
        try write(bytes: 60_000, to: fixedTraceRecord)
        try write(bytes: 90_000, to: screenshot)
        try write(bytes: 400_000, to: ordinaryScreenshots.appendingPathComponent("family-photo.png"))
        try write(bytes: 600_000, to: playwright.appendingPathComponent("portrait.png"))
        try write(bytes: 1_100_000, to: playwright.appendingPathComponent("source-backup.zip"))
        try write(bytes: 700_000, to: playwright.appendingPathComponent("Resume.pdf"))
        try write(bytes: 900_000, to: playwright.appendingPathComponent("Resume.docx"))
        try write(bytes: 2_000_000, to: generatedInstaller)
        try write(bytes: 1_500_000, to: downloadedInstaller)
        try write(bytes: 400_000, to: functionCheck.appendingPathComponent("scan-final.png"))
        try write(bytes: 3_000_000, to: release.appendingPathComponent("Project.dmg"))
        try write(bytes: 2_500_000, to: release.appendingPathComponent("Project.zip"))
        try write(bytes: 1_500_000, to: distApp.appendingPathComponent("payload"))
        try write(bytes: 1_200_000, to: temporaryBuild.appendingPathComponent("payload"))
        try write(bytes: 350_000, to: systemTemporary.appendingPathComponent("storage-cleaner-scan.png"))

        let result = CodexArtifactScanner(
            configuration: makeConfiguration(
                codexTemporary: codexTemporary,
                generatedImages: generatedImages,
                workspace: workspace,
                systemTemporary: systemTemporary
            )
        ).scan(deadline: Date().addingTimeInterval(10))

        let runtimeDebug = result.runtimeRecordEntries.map { "\($0.path)=\($0.sizeBytes)" }.joined(separator: " | ")
        let installerDebug = result.installerEntries.map { "\($0.path)=\($0.sizeBytes)" }.joined(separator: " | ")
        XCTAssertFalse(result.wasLimited)
        XCTAssertEqual(result.intermediateEntries.map(\.path), [PathSafety.normalizedPath(codexTemporary.path)])
        XCTAssertTrue(result.runtimeRecordEntries.contains { $0.path == PathSafety.normalizedPath(generatedImages.path) })
        let expectedRuntimeBytes = allocatedSize(of: pageRecord)
            + allocatedSize(of: consoleRecord)
            + allocatedSize(of: fixedPageRecord)
            + allocatedSize(of: fixedTraceRecord)
            + allocatedSize(of: screenshot)
        XCTAssertTrue(result.runtimeRecordEntries.contains { $0.path == PathSafety.normalizedPath(playwright.path) && $0.sizeBytes == expectedRuntimeBytes }, runtimeDebug)
        XCTAssertTrue(result.runtimeRecordEntries.contains { $0.path == PathSafety.normalizedPath(functionCheck.path) }, runtimeDebug)
        XCTAssertTrue(result.installerEntries.contains { $0.path == PathSafety.normalizedPath(temporaryBuild.path) }, installerDebug)
        XCTAssertTrue(result.runtimeRecordEntries.contains { $0.path.hasSuffix("storage-cleaner-scan.png") })
        XCTAssertTrue(result.installerEntries.contains {
            $0.path == PathSafety.normalizedPath(generatedInstaller.path)
                && $0.sizeBytes == allocatedSize(of: generatedInstaller) + allocatedSize(of: downloadedInstaller)
        })
        XCTAssertFalse(result.installerEntries.contains { $0.path.hasSuffix("source-backup.zip") })
        XCTAssertTrue(result.installerEntries.contains { $0.path == PathSafety.normalizedPath(release.path) }, installerDebug)
        XCTAssertTrue(result.installerEntries.contains { $0.path == PathSafety.normalizedPath(project.appendingPathComponent("dist").path) }, installerDebug)

        let allPaths = (result.intermediateEntries + result.runtimeRecordEntries + result.installerEntries).map(\.path)
        XCTAssertFalse(allPaths.contains { $0.contains("sessions") })
        XCTAssertFalse(allPaths.contains(PathSafety.normalizedPath(ordinaryScreenshots.path)))
        XCTAssertFalse(allPaths.contains { $0.hasSuffix("Resume.pdf") || $0.hasSuffix("Resume.docx") })
    }

    func testClassificationOnlyMakesCodexTemporaryAreaAutoCleanable() throws {
        let codexTemporary = sandbox.appendingPathComponent(".codex/.tmp", isDirectory: true)
        let screenshots = sandbox.appendingPathComponent("release/function-check", isDirectory: true)
        let release = sandbox.appendingPathComponent("release", isDirectory: true)
        try FileManager.default.createDirectory(at: codexTemporary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)

        let groups = [
            StorageGroup(
                id: "codex_intermediates",
                title: "Codex Temporary Files",
                entries: [DirectoryEntry(name: "Temp", path: codexTemporary.path, sizeBytes: 10, isDirectory: true)]
            ),
            StorageGroup(
                id: "codex_runtime_records",
                title: "Codex Screenshots",
                entries: [DirectoryEntry(name: "Screenshots", path: screenshots.path, sizeBytes: 20, isDirectory: true)]
            ),
            StorageGroup(
                id: "codex_installers",
                title: "Codex Installers",
                entries: [DirectoryEntry(name: "Release", path: release.path, sizeBytes: 30, isDirectory: true)]
            )
        ]

        let items = StorageClassifier.classify(groups: groups)
        let temporaryItem = try XCTUnwrap(items.first { $0.sourceID == "codex_intermediates" })
        let screenshotItem = try XCTUnwrap(items.first { $0.sourceID == "codex_runtime_records" })
        let installerItem = try XCTUnwrap(items.first { $0.sourceID == "codex_installers" })

        XCTAssertEqual(temporaryItem.tier, .green)
        XCTAssertTrue(temporaryItem.canMoveToTrash)
        XCTAssertEqual(temporaryItem.trashPaths, [codexTemporary.path])
        XCTAssertEqual(screenshotItem.tier, .yellow)
        XCTAssertFalse(screenshotItem.canMoveToTrash)
        XCTAssertTrue(screenshotItem.trashPaths.isEmpty)
        XCTAssertEqual(installerItem.tier, .yellow)
        XCTAssertFalse(installerItem.canMoveToTrash)
        XCTAssertTrue(installerItem.trashPaths.isEmpty)
    }

    func testKnownAgentArtifactPathsOnlyIncludeExplicitCachesTemporaryFilesAndReviewLogs() {
        let greenPaths = Set(DiskScanner.knownRegenerableAgentPaths.map(\.path))
        let expectedGreenPaths = Set(DeveloperToolArtifactCatalog.definitions
            .filter { $0.policy == .regenerable }
            .flatMap { definition in
                definition.candidateNames.map { "~/\(definition.rootPath)/\($0)" }
            })
        XCTAssertEqual(greenPaths, expectedGreenPaths)

        let reviewPaths = Set(DiskScanner.knownAgentLogPaths.map(\.path))
        let expectedReviewPaths = Set(DeveloperToolArtifactCatalog.definitions
            .filter { $0.policy == .reviewOnly }
            .flatMap { definition in
                definition.candidateNames.map { "~/\(definition.rootPath)/\($0)" }
            }).union(["/tmp/openclaw"])
        XCTAssertEqual(reviewPaths, expectedReviewPaths)

        let recognizedPaths = greenPaths.union(reviewPaths)
        let protectedPaths = [
            "~/.codex/auth.json",
            "~/.codex/config.toml",
            "~/.codex/history.jsonl",
            "~/.codex/memories",
            "~/.codex/sessions",
            "~/.claude.json",
            "~/.claude/settings.json",
            "~/.claude/.credentials.json",
            "~/.claude/agents",
            "~/.claude/projects",
            "~/.claude/sessions",
            "~/.claude/session-env",
            "~/.claude/skills",
            "~/.claude/hooks",
            "~/.claude/backups",
            "~/.claude/history.jsonl",
            "~/.claude/file-history",
            "~/.claude/plans",
            "~/.claude/plugins/data",
            "~/Library/Application Support/Cursor/User",
            "~/Library/Application Support/Cursor/User/globalStorage/github.copilot",
            "~/Library/Application Support/Cursor/User/workspaceStorage",
            "~/Library/Application Support/Code/User/globalStorage/github.copilot",
            "~/.config/opencode",
            "~/.local/share/opencode/storage",
            "~/.local/share/opencode/session",
            "~/.openclaw/openclaw.json",
            "~/.openclaw/credentials",
            "~/.openclaw/identity",
            "~/.openclaw/state",
            "~/.openclaw/memory",
            "~/.openclaw/agents",
            "~/.openclaw/tasks",
            "~/.openclaw/cron",
            "~/.openclaw/workspace",
            "~/.openclaw/workspace-attestations",
            "~/.openclaw/plugins",
            "~/.openclaw/plugin-skills",
            "~/.openclaw/skills",
            "~/.openclaw/flows",
            "~/.openclaw/browser",
            "~/.openclaw/media",
            "~/.openclaw/sessions",
            "~/.openclaw/sandboxes",
            "~/.openclaw/backups",
            "~/.openclaw/locks"
        ]
        XCTAssertTrue(recognizedPaths.isDisjoint(with: protectedPaths))
        for recognizedPath in recognizedPaths {
            XCTAssertFalse(
                protectedPaths.contains { pathsIntersect(recognizedPath, $0) },
                "Known cleanup path must not contain or be contained by protected state: \(recognizedPath)"
            )
        }
    }

    private func pathsIntersect(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    func testAgentCachesAreGreenWhileLogsRequireReview() throws {
        let cachePath = sandbox.appendingPathComponent(".claude/cache", isDirectory: true).path
        let logPath = sandbox.appendingPathComponent(".openclaw/logs", isDirectory: true).path
        let items = StorageClassifier.classify(
            groups: [
                StorageGroup(
                    id: "dev_caches",
                    title: "Developer Cache",
                    entries: [
                        DirectoryEntry(
                            name: "Claude Code Cache",
                            path: cachePath,
                            sizeBytes: 1_000,
                            isDirectory: true
                        )
                    ]
                ),
                StorageGroup(
                    id: "codex_runtime_records",
                    title: "Runtime Records",
                    entries: [
                        DirectoryEntry(
                            name: "OpenClaw Logs",
                            path: logPath,
                            sizeBytes: 2_000,
                            isDirectory: true
                        )
                    ]
                )
            ]
        )

        let cache = try XCTUnwrap(items.first { $0.path == cachePath })
        let logs = try XCTUnwrap(items.first { $0.path == logPath })
        XCTAssertEqual(cache.tier, .green)
        XCTAssertTrue(cache.canMoveToTrash)
        XCTAssertEqual(cache.trashPaths, [cachePath])
        XCTAssertEqual(logs.tier, .yellow)
        XCTAssertFalse(logs.canMoveToTrash)
        XCTAssertTrue(logs.trashPaths.isEmpty)
    }

    func testAgentArtifactClassificationDeduplicatesNormalizedPathsWithoutChangingCodexPriority() {
        let sharedPath = sandbox.appendingPathComponent(".claude/cache", isDirectory: true).path
        let duplicate = DirectoryEntry(
            name: "Duplicate",
            path: sharedPath,
            sizeBytes: 1_000,
            isDirectory: true
        )
        let items = StorageClassifier.classify(
            groups: [
                StorageGroup(id: "logs", title: "Logs", entries: [duplicate]),
                StorageGroup(id: "dev_caches", title: "Developer Cache", entries: [duplicate]),
                StorageGroup(id: "codex_runtime_records", title: "Codex Records", entries: [duplicate])
            ]
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.sourceID, "codex_runtime_records")
        XCTAssertEqual(items.first?.tier, .yellow)
        XCTAssertFalse(items.first?.canMoveToTrash ?? true)
    }

    func testScannerHonorsExcludedReleaseAncestorWithoutPrefixCollision() throws {
        let workspace = sandbox.appendingPathComponent("Documents", isDirectory: true)
        let excludedProject = workspace.appendingPathComponent("Project", isDirectory: true)
        let excludedRelease = excludedProject.appendingPathComponent("release", isDirectory: true)
        let includedRelease = workspace.appendingPathComponent("Project-old/release", isDirectory: true)
        try FileManager.default.createDirectory(at: excludedRelease, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: includedRelease, withIntermediateDirectories: true)
        try write(bytes: 1_000, to: excludedRelease.appendingPathComponent("Excluded.dmg"))
        try write(bytes: 1_000, to: includedRelease.appendingPathComponent("Included.dmg"))

        var configuration = makeConfiguration(workspace: workspace)
        configuration = configurationWith(configuration, excludedPaths: [excludedProject.path])
        let result = CodexArtifactScanner(configuration: configuration)
            .scan(deadline: Date().addingTimeInterval(10))

        XCTAssertFalse(result.installerEntries.contains { $0.path == PathSafety.normalizedPath(excludedRelease.path) })
        XCTAssertTrue(result.installerEntries.contains { $0.path == PathSafety.normalizedPath(includedRelease.path) }, result.installerEntries.map(\.path).joined(separator: " | "))
        XCTAssertFalse(result.wasLimited)
    }

    func testScannerDoesNotOfferCodexTemporaryParentWhenExcludedItemIsInsideIt() throws {
        let codexTemporary = sandbox.appendingPathComponent(".codex/.tmp", isDirectory: true)
        let excludedChild = codexTemporary.appendingPathComponent("keep/session-state.bin")
        try write(bytes: 2_000, to: codexTemporary.appendingPathComponent("safe-cache.bin"))
        try write(bytes: 2_000, to: excludedChild)

        var configuration = makeConfiguration(codexTemporary: codexTemporary)
        configuration = configurationWith(configuration, excludedPaths: [excludedChild.path])
        let result = CodexArtifactScanner(configuration: configuration)
            .scan(deadline: Date().addingTimeInterval(10))

        XCTAssertTrue(result.intermediateEntries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: excludedChild.path))
        XCTAssertFalse(result.wasLimited)
    }

    func testScannerClassifiesNamedCodexTemporaryOutputsWithoutIncludingActiveBrowserDirectory() throws {
        let systemTemporary = sandbox.appendingPathComponent("private-tmp", isDirectory: true)
        let codexBuild = systemTemporary.appendingPathComponent("codex-score-build", isDirectory: true)
        let activeBrowser = systemTemporary.appendingPathComponent("codex-browser-use", isDirectory: true)
        let codexApp = systemTemporary.appendingPathComponent("codex-preview.app", isDirectory: true)
        let storageCleanerApp = systemTemporary.appendingPathComponent("StorageCleanerMac.app", isDirectory: true)
        let screenshot = systemTemporary.appendingPathComponent("codex-screenshot.png")
        let package = systemTemporary.appendingPathComponent("codex-output.dmg")

        try write(bytes: 2_000, to: codexBuild.appendingPathComponent("payload"))
        try write(bytes: 2_000, to: activeBrowser.appendingPathComponent("profile/Preferences"))
        try write(bytes: 2_000, to: codexApp.appendingPathComponent("Contents/MacOS/App"))
        try write(bytes: 2_000, to: storageCleanerApp.appendingPathComponent("Contents/MacOS/App"))
        try write(bytes: 2_000, to: screenshot)
        try write(bytes: 2_000, to: package)

        let result = CodexArtifactScanner(
            configuration: makeConfiguration(systemTemporary: systemTemporary)
        ).scan(deadline: Date().addingTimeInterval(10))

        let runtimePaths = Set(result.runtimeRecordEntries.map(\.path))
        let installerPaths = Set(result.installerEntries.map(\.path))
        XCTAssertFalse(runtimePaths.contains(PathSafety.normalizedPath(codexBuild.path)))
        XCTAssertTrue(runtimePaths.contains(PathSafety.normalizedPath(screenshot.path)))
        XCTAssertFalse(runtimePaths.contains(PathSafety.normalizedPath(activeBrowser.path)))
        XCTAssertFalse(runtimePaths.contains(PathSafety.normalizedPath(codexApp.path)))
        XCTAssertFalse(runtimePaths.contains(PathSafety.normalizedPath(storageCleanerApp.path)))
        XCTAssertTrue(installerPaths.contains(PathSafety.normalizedPath(codexApp.path)))
        XCTAssertTrue(installerPaths.contains(PathSafety.normalizedPath(storageCleanerApp.path)))
        XCTAssertTrue(installerPaths.contains(PathSafety.normalizedPath(codexBuild.path)))
        XCTAssertTrue(installerPaths.contains(PathSafety.normalizedPath(package.path)))
    }

    func testScannerSkipsSymlinkedCodexTemporaryDirectory() throws {
        let outside = sandbox.appendingPathComponent("outside", isDirectory: true)
        let link = sandbox.appendingPathComponent(".codex/.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(bytes: 1_000, to: outside.appendingPathComponent("keep.bin"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = CodexArtifactScanner(
            configuration: makeConfiguration(codexTemporary: link)
        ).scan(deadline: Date().addingTimeInterval(10))

        XCTAssertTrue(result.intermediateEntries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
    }

    func testScannerReportsImmediateDeadlineAndCandidateLimit() throws {
        let generatedImages = sandbox.appendingPathComponent("generated_images", isDirectory: true)
        let systemTemporary = sandbox.appendingPathComponent("private-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedImages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: systemTemporary, withIntermediateDirectories: true)
        try write(bytes: 1_000, to: generatedImages.appendingPathComponent("exec.png"))
        try write(bytes: 1_000, to: systemTemporary.appendingPathComponent("storage-cleaner-one.png"))

        let expired = CodexArtifactScanner(
            configuration: makeConfiguration(generatedImages: generatedImages, systemTemporary: systemTemporary)
        ).scan(deadline: Date().addingTimeInterval(-1))
        XCTAssertTrue(expired.wasLimited)
        XCTAssertTrue(expired.runtimeRecordEntries.isEmpty)

        var limitedConfiguration = makeConfiguration(
            generatedImages: generatedImages,
            systemTemporary: systemTemporary
        )
        limitedConfiguration = configurationWith(limitedConfiguration, maxCandidates: 1)
        let limited = CodexArtifactScanner(configuration: limitedConfiguration)
            .scan(deadline: Date().addingTimeInterval(10))
        XCTAssertTrue(limited.wasLimited)
        XCTAssertEqual(
            limited.intermediateEntries.count + limited.runtimeRecordEntries.count + limited.installerEntries.count,
            1
        )
    }

    func testDirectorySizeQueryLimitKeepsCompletedPartialResults() throws {
        let systemTemporary = sandbox.appendingPathComponent("private-tmp", isDirectory: true)
        let firstBuild = systemTemporary.appendingPathComponent("storage-cleaner-a-build", isDirectory: true)
        let secondBuild = systemTemporary.appendingPathComponent("storage-cleaner-b-build", isDirectory: true)
        try write(bytes: 2_000, to: firstBuild.appendingPathComponent("payload"))
        try write(bytes: 2_000, to: secondBuild.appendingPathComponent("payload"))

        var configuration = makeConfiguration(systemTemporary: systemTemporary)
        configuration = configurationWith(configuration, maxDirectorySizeQueries: 1)
        let result = CodexArtifactScanner(configuration: configuration)
            .scan(deadline: Date().addingTimeInterval(10))

        XCTAssertTrue(result.wasLimited)
        XCTAssertEqual(result.installerEntries.map(\.path), [PathSafety.normalizedPath(firstBuild.path)])
    }

    func testDevArtifactsFilterIncludesAllCodexGroups() {
        let sourceIDs = ["dev_caches", "codex_intermediates", "codex_runtime_records", "codex_installers"]
        let items = sourceIDs.enumerated().map { index, sourceID in
            StorageItem(
                id: sourceID,
                title: sourceID,
                path: "/tmp/\(sourceID)",
                sourceID: sourceID,
                groupTitle: sourceID,
                sizeBytes: Int64(index + 1),
                tier: sourceID == "codex_intermediates" ? .green : .yellow,
                kind: sourceID,
                reason: "",
                recommendation: "",
                risk: "",
                requiresClose: "",
                trashPaths: [],
                openPath: "/tmp/\(sourceID)",
                isDirectory: true,
                status: .available
            )
        }
        let result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0,
            system: makeSnapshot(),
            groups: [],
            items: items,
            deniedPaths: []
        )

        XCTAssertEqual(Set(result.items(for: .devCaches).map(\.sourceID)), Set(sourceIDs))
    }

    func testTierBytesDoNotDoubleCountCodexChildCoveredByLargeDirectory() {
        func item(_ sourceID: String, path: String, bytes: Int64, isDirectory: Bool = true) -> StorageItem {
            StorageItem(
                id: path,
                title: sourceID,
                path: path,
                sourceID: sourceID,
                groupTitle: sourceID,
                sizeBytes: bytes,
                tier: .yellow,
                kind: sourceID,
                reason: "",
                recommendation: "",
                risk: "",
                requiresClose: "",
                trashPaths: [],
                openPath: path,
                isDirectory: isDirectory,
                status: .available
            )
        }

        let projectRoot = sandbox.appendingPathComponent("Documents/Projects", isDirectory: true).path
        let result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0,
            system: makeSnapshot(),
            groups: [],
            items: [
                item("large_files", path: projectRoot, bytes: 1_000),
                item("codex_installers", path: projectRoot + "/StorageCleanerMac/release", bytes: 400),
                item("codex_runtime_records", path: sandbox.appendingPathComponent("elsewhere/screenshots").path, bytes: 200)
            ],
            deniedPaths: []
        )

        XCTAssertEqual(result.items(forTier: .yellow).count, 3)
        XCTAssertEqual(result.yellowBytes, 1_200)
        XCTAssertEqual(result.identifiedDecisionBytes, 1_200)
    }

    func testTierBytesKeepGreenValueWhileRemovingCrossTierLargeDirectoryOverlap() {
        func item(_ sourceID: String, path: String, bytes: Int64, tier: StorageTier) -> StorageItem {
            StorageItem(
                id: sourceID + path,
                title: sourceID,
                path: path,
                sourceID: sourceID,
                groupTitle: sourceID,
                sizeBytes: bytes,
                tier: tier,
                kind: sourceID,
                reason: "",
                recommendation: "",
                risk: "",
                requiresClose: "",
                trashPaths: [],
                openPath: path,
                isDirectory: true,
                status: .available
            )
        }

        let projectRoot = sandbox.appendingPathComponent("Documents/Projects", isDirectory: true).path
        let result = ScanResult(
            generatedAt: Date(),
            scanSeconds: 0,
            system: makeSnapshot(),
            groups: [],
            items: [
                item("large_files", path: projectRoot, bytes: 1_000, tier: .yellow),
                item("dev_caches", path: projectRoot + "/StorageCleanerMac/.build", bytes: 200, tier: .green),
                item("codex_installers", path: projectRoot + "/StorageCleanerMac/release", bytes: 400, tier: .yellow),
                item("codex_runtime_records", path: sandbox.appendingPathComponent("elsewhere/screenshots").path, bytes: 300, tier: .yellow)
            ],
            deniedPaths: []
        )

        XCTAssertEqual(result.greenBytes, 200)
        XCTAssertEqual(result.yellowBytes, 1_100)
        XCTAssertEqual(result.identifiedDecisionBytes, 1_300)
        XCTAssertEqual(result.otherUsedBytes, 0)
    }

    private func makeConfiguration(
        codexTemporary: URL? = nil,
        generatedImages: URL? = nil,
        workspace: URL? = nil,
        systemTemporary: URL? = nil
    ) -> CodexArtifactScanner.Configuration {
        CodexArtifactScanner.Configuration(
            codexTemporaryDirectories: codexTemporary.map { [$0] } ?? [],
            generatedImageDirectories: generatedImages.map { [$0] } ?? [],
            workspaceRoots: workspace.map { [$0] } ?? [],
            systemTemporaryDirectories: systemTemporary.map { [$0] } ?? [],
            excludedPaths: [],
            scanBudget: 5,
            directoryReadTimeout: 1,
            directorySizeTimeout: 1,
            maxTraversalDepth: 2,
            maxVisitedDirectories: 100,
            maxInspectedEntries: 1_000,
            maxDirectorySizeQueries: 20,
            maxCandidates: 100,
            minimumIntermediateBytes: 1,
            minimumRuntimeRecordBytes: 1,
            minimumInstallerBytes: 1
        )
    }

    private func configurationWith(
        _ configuration: CodexArtifactScanner.Configuration,
        excludedPaths: [String]? = nil,
        maxDirectorySizeQueries: Int? = nil,
        maxCandidates: Int? = nil
    ) -> CodexArtifactScanner.Configuration {
        CodexArtifactScanner.Configuration(
            codexTemporaryDirectories: configuration.codexTemporaryDirectories,
            generatedImageDirectories: configuration.generatedImageDirectories,
            workspaceRoots: configuration.workspaceRoots,
            systemTemporaryDirectories: configuration.systemTemporaryDirectories,
            excludedPaths: excludedPaths ?? configuration.excludedPaths,
            scanBudget: configuration.scanBudget,
            directoryReadTimeout: configuration.directoryReadTimeout,
            directorySizeTimeout: configuration.directorySizeTimeout,
            maxTraversalDepth: configuration.maxTraversalDepth,
            maxVisitedDirectories: configuration.maxVisitedDirectories,
            maxInspectedEntries: configuration.maxInspectedEntries,
            maxDirectorySizeQueries: maxDirectorySizeQueries ?? configuration.maxDirectorySizeQueries,
            maxCandidates: maxCandidates ?? configuration.maxCandidates,
            minimumIntermediateBytes: configuration.minimumIntermediateBytes,
            minimumRuntimeRecordBytes: configuration.minimumRuntimeRecordBytes,
            minimumInstallerBytes: configuration.minimumInstallerBytes
        )
    }

    private func write(bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func allocatedSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private func makeSnapshot() -> SystemSnapshot {
        SystemSnapshot(
            osName: "macOS",
            build: "test",
            arch: "arm64",
            user: "tester",
            home: sandbox.path,
            filesystem: "APFS",
            purgeable: "",
            diskName: "Test",
            diskTotalBytes: 1_000,
            diskUsedBytes: 500,
            diskFreeBytes: 500
        )
    }
}
