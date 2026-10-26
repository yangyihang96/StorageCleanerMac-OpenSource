import Foundation
import XCTest
@testable import StorageCleanerMac

final class ProjectArtifactTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let home = try TestFileSystem.makeHome(for: self)
        let project = home.appendingPathComponent("Projects/sample")
        try TestFileSystem.createDirectory(at: project)
        return (home, project)
    }
    private func write(_ path: String, in root: URL, text: String = "fixture") throws {
        let url = root.appendingPathComponent(path)
        try TestFileSystem.createDirectory(at: url.deletingLastPathComponent())
        let content = path.hasSuffix("pyvenv.cfg") && text == "fixture" ? "home = \(root.appendingPathComponent("toolchain/bin").path)\n" : text
        try Data(content.utf8).write(to: url)
    }
    private func artifact(_ name: String, in project: URL) throws {
        let leaf = URL(fileURLWithPath: name).lastPathComponent
        if leaf == "__pycache__" { try write(name + "/generated.pyc", in: project); return }
        try write(name + "/generated.bin", in: project)
        let markers = ["node_modules": ".package-lock.json", "target": "CACHEDIR.TAG", ".build": "workspace-state.json", ".pytest_cache": "CACHEDIR.TAG", ".mypy_cache": "CACHEDIR.TAG", "vendor": "composer/installed.json", ".dart_tool": "package_config.json"]
        if let marker = markers[leaf] { try write(name + "/" + marker, in: project) }
        // Generic outputs have no universal generated marker; these selectable fixtures use Git evidence.
        if ["build", "dist", ".gradle"].contains(leaf) {
            try git(["init", "-q"], in: project)
            try write(".gitignore", in: project, text: "build/\ndist/\n.gradle/\n")
        }
    }
    private func scan(home: URL, project: URL, limits: ProjectArtifactScanLimits = .init()) throws -> ProjectArtifactScanResult {
        try ProjectArtifactScanner(fileSystem: RuleTestReadOnlyFileSystem(root: home), limits: limits, home: home).scanSynchronously(roots: [project])
    }
    func testProjectCatalogUsesD82MaintenanceAndRevisionBaseline() throws {
        let home = URL(fileURLWithPath: "/project-baseline")
        let rules = ProjectArtifactRequirement.catalog.map { $0.rule(project: home.appendingPathComponent("Projects/sample"), home: home) }
        let set = CleanupRuleSet(schemaVersion: 2, rulesVersion: "project-catalog", rules: rules)
        let baseline = try JSONDecoder().decode(CleanupRuleBaseline.self, from: Data(contentsOf: CleanupRuleTestFixtures.resourceURL("ProjectArtifacts.baseline.json")))
        XCTAssertEqual(baseline.entries.count, rules.count)
        try CleanupRuleValidator.validate(set)
        try CleanupRuleMaintenanceValidator.validate(set, baseline: baseline)
        var changed = rules[0]
        changed.projectArtifact = .init(ecosystem: "npm", manifest: "package.json", relativeArtifact: "node_modules", rebuildCommand: "changed rebuild", evidenceURL: rules[0].projectArtifact!.evidenceURL)
        let changedSet = CleanupRuleSet(schemaVersion: 2, rulesVersion: set.rulesVersion, rules: [changed])
        XCTAssertThrowsError(try CleanupRuleMaintenanceValidator.validate(changedSet, baseline: baseline))
        changed.maintenance?.revision += 1
        XCTAssertNoThrow(try CleanupRuleMaintenanceValidator.validate(CleanupRuleSet(schemaVersion: 2, rulesVersion: set.rulesVersion, rules: [changed]), baseline: baseline))
    }
    func testEveryEcosystemRequiresItsManifest() throws {
        for (manifest, paths) in [
            ("package.json", ["node_modules"]), ("Cargo.toml", ["target"]),
            ("pyproject.toml", ["__pycache__", ".pytest_cache", ".mypy_cache"]),
            ("requirements.txt", ["__pycache__"]), ("setup.py", ["__pycache__"]),
            ("Package.swift", [".build"]), ("build.gradle", ["build", ".gradle"]),
            ("build.gradle.kts", ["build"]), ("pom.xml", ["target"]),
            ("composer.json", ["vendor"]), ("pubspec.yaml", ["build", ".dart_tool"])
        ] {
            let (home, project) = try fixture()
            for path in paths { try artifact(path, in: project) }
            XCTAssertTrue(try scan(home: home, project: project).rows.isEmpty, manifest)
            try write(manifest, in: project, text: manifest == "package.json" ? "{}" : "fixture")
            try git(["init", "-q"], in: project)
            try write(".gitignore", in: project, text: paths.map { $0 + "/" }.joined(separator: "\n") + "\n")
            let result = try scan(home: home, project: project)
            XCTAssertEqual(Set(result.rows.map { $0.requirement.relativeArtifact }), Set(paths), manifest)
            XCTAssertTrue(result.rows.allSatisfy { $0.blockedReason == nil }, manifest)
            XCTAssertTrue(CleanupSelection.defaults(in: result.session).selectedCandidateIDs.isEmpty)
            XCTAssertTrue(result.rows.allSatisfy { $0.candidate.defaultSelection == .unselected })
        }
    }
    func testMixedEcosystemsClaimOneArtifactAndBuildOnePlanItem() throws {
        let (home, project) = try fixture()
        try write("package.json", in: project, text: "{\"scripts\":{\"build\":\"tool --output build\"}}")
        try write("build.gradle", in: project); try write("pubspec.yaml", in: project)
        try artifact("build", in: project)
        let result = try scan(home: home, project: project)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].requirement.ecosystem, "npm")
        var selection = CleanupSelection()
        selection.setCandidates(result.rows.map(\.id), selected: true, in: result.session)
        let plan = try CleanPlanBuilder.makePlan(session: result.session, selection: selection, activeRules: result.rules, disposition: .trash)
        XCTAssertEqual(plan.items.count, 1)
    }
    func testNodeBuildOutputsRequireCorrespondingBuildScript() throws {
        let (home, project) = try fixture()
        for name in ["dist", "build", ".next"] { try artifact(name, in: project) }
        try write("package.json", in: project, text: "{\"scripts\":{\"test\":\"echo build dist\"}}")
        XCTAssertTrue(try scan(home: home, project: project).rows.isEmpty)
        try write(".next/BUILD_ID", in: project); try write(".next/server/page.js", in: project)
        try write("package.json", in: project, text: "{\"scripts\":{\"build\":\"next build && tool --outDir dist && tool --output build\"}}")
        XCTAssertEqual(try scan(home: home, project: project).rows.count, 3)
        try write("package.json", in: project, text: "{\"scripts\":{\"build\":\"unknown-compiler\"}}")
        XCTAssertTrue(try scan(home: home, project: project).rows.isEmpty)
    }
    func testVenvRequiresPyvenvCfgAndManifest() throws {
        let (home, project) = try fixture()
        try write("requirements.txt", in: project)
        for name in ["venv", ".venv"] { try artifact(name, in: project) }
        let missing = try scan(home: home, project: project)
        XCTAssertEqual(missing.rows.count, 2)
        XCTAssertTrue(missing.rows.allSatisfy { !$0.candidate.isSelectable && $0.blockedReason?.contains("缺少 pyvenv.cfg") == true })
        for name in ["venv", ".venv"] { try write(name + "/pyvenv.cfg", in: project) }
        XCTAssertTrue(try scan(home: home, project: project).rows.allSatisfy { $0.candidate.isSelectable })
    }
    func testBundlerRequiresExactConfiguredVendorBundle() throws {
        let (home, project) = try fixture()
        try write("Gemfile", in: project); try artifact("vendor/bundle", in: project)
        XCTAssertTrue(try scan(home: home, project: project).rows.isEmpty)
        try write(".bundle/config", in: project, text: "BUNDLE_PATH: \"vendor/other\"\n")
        XCTAssertTrue(try scan(home: home, project: project).rows.isEmpty)
        try write(".bundle/config", in: project, text: "---\nBUNDLE_PATH: \"vendor/bundle\"\n")
        XCTAssertEqual(try scan(home: home, project: project).rows.count, 1)
    }
    func testGoAndXcodeDoNotIntroduceProjectOutputs() throws {
        let (home, project) = try fixture()
        try write("go.mod", in: project); try artifact("build", in: project)
        try TestFileSystem.createDirectory(at: project.appendingPathComponent("Example.xcodeproj"))
        try TestFileSystem.createDirectory(at: project.appendingPathComponent("Example.xcworkspace"))
        XCTAssertTrue(try scan(home: home, project: project).rows.isEmpty)
    }
    func testNestedPythonCachesAndNoDiscoveryInsideArtifacts() throws {
        let (home, project) = try fixture()
        try write("pyproject.toml", in: project); try artifact("src/__pycache__", in: project)
        try write("src/__pycache__/fake/package.json", in: project, text: "{}")
        try artifact("src/__pycache__/fake/node_modules", in: project)
        let result = try scan(home: home, project: project)
        XCTAssertEqual(result.rows.map { $0.requirement.relativeArtifact }, ["src/__pycache__"])
        XCTAssertEqual(result.rows.first?.project, project)
    }
    func testLocksSourceConfigurationAndEnvAreNeverRows() throws {
        let (home, project) = try fixture()
        try write("package.json", in: project, text: "{}")
        for name in ["package-lock.json", "yarn.lock", "Cargo.lock", "poetry.lock", ".env", ".env.production", "src/main.swift", "config.json"] { try write(name, in: project) }
        try artifact("node_modules", in: project)
        XCTAssertEqual(try scan(home: home, project: project).rows.map { $0.candidate.sourceURL.lastPathComponent }, ["node_modules"])
        for name in ["package-lock.json", "yarn.lock", "Cargo.lock", "poetry.lock", ".env", ".git", "users.db"] {
            XCTAssertTrue(ProjectArtifactScanner.protectedName(name), name)
        }
    }
    func testProtectedMarkersInsideArtifactForbidWholeRow() throws {
        for name in [".git/HEAD", ".env.production", "Cargo.lock", "users.sqlite"] {
            let (home, project) = try fixture()
            try write("Cargo.toml", in: project); try artifact("target", in: project); try write("target/" + name, in: project)
            let row = try XCTUnwrap(scan(home: home, project: project).rows.first)
            XCTAssertFalse(row.candidate.isSelectable, name)
        }
    }
    func testBuildOutputCannotAbsorbHandMaintainedSourceOrConfig() throws {
        let (home, project) = try fixture()
        try write("package.json", in: project, text: "{\"scripts\":{\"build\":\"tool --outDir dist\"}}")
        try artifact("dist", in: project); try write("dist/src/main.ts", in: project)
        let row = try XCTUnwrap(scan(home: home, project: project).rows.first)
        XCTAssertFalse(row.candidate.isSelectable)
        XCTAssertTrue(row.blockedReason?.contains("保护标记") == true)
    }
    func testDisplayOnlyRowsAreNotShownAsZeroBytes() throws {
        let (home, project) = try fixture()
        try write("requirements.txt", in: project)
        try artifact(".venv", in: project)
        let rows = try scan(home: home, project: project).rows
        let row = try XCTUnwrap(rows.first)
        XCTAssertNotNil(row.blockedReason)
        XCTAssertEqual(row.candidate.estimatedSizeBytes, 0)
        XCTAssertEqual(ProjectArtifactView.sizeText(row), "未测量")
        let view = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/ProjectArtifactView.swift")
        XCTAssertTrue(view.contains("\"扫描范围：\""))
        XCTAssertTrue(view.contains("@Published private(set) var roots"))
    }
    func testSymlinkArtifactAndInternalLinkAreReadOnly() throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("other", in: project)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("target"), withDestinationURL: project.appendingPathComponent("other"))
        let row = try XCTUnwrap(scan(home: home, project: project).rows.first)
        XCTAssertFalse(row.candidate.isSelectable)
        XCTAssertTrue(row.blockedReason?.contains("符号链接") == true)
        try FileManager.default.removeItem(at: project.appendingPathComponent("target"))
        try artifact("target", in: project)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("target/link"), withDestinationURL: project.appendingPathComponent("other"))
        XCTAssertFalse(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable)
    }
    func testCloudAssessmentDoesNotReadMetadata() throws {
        let (home, project) = try fixture()
        let reader = ArtifactMetadataOverride(base: RuleTestReadOnlyFileSystem(root: home), overrideVolumeAt: nil)
        let requirement = ProjectArtifactRequirement.catalog.first { $0.ecosystem == "Cargo" }!
        let cloud = project.appendingPathComponent("Library/CloudStorage/provider/target")
        let assessment = ProjectArtifactScanner(fileSystem: reader, home: home).assess(artifact: cloud, project: project, requirement: requirement)
        XCTAssertNil(assessment.snapshot)
        XCTAssertTrue(assessment.reason?.contains("云盘") == true)
        XCTAssertTrue(ProjectArtifactScanner.isCloudPath(project.appendingPathComponent("Library/Mobile Documents/x")))
        XCTAssertTrue(ProjectArtifactScanner.isCloudPath(project.appendingPathComponent("iCloud/x")))
    }
    func testSelectedCloudScopeIsDisplayedWithoutTraversal() throws {
        let (home, project) = try fixture()
        let cloud = project.appendingPathComponent("Library/CloudStorage/provider")
        let result = try scan(home: home, project: cloud)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.scopeWarnings.count, 1)
        XCTAssertTrue(result.scopeWarnings[0].contains("未遍历"))
    }
    /// D104 G1: each regular file of a listed artifact is read for sharing
    /// once, while the artifact is measured, and the row keeps what emptying
    /// the Trash frees; the check before the move reads nothing extra, and a
    /// row that is only shown keeps no estimate.
    func testListedRowsReadSharingAndTheMoveCheckDoesNot() throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("target", in: project)
        try write("target/debug/app.rlib", in: project, text: String(repeating: "x", count: 8_192))
        let rlib = project.appendingPathComponent("target/debug/app.rlib")
        let rlibBytes = Int64(try XCTUnwrap(rlib.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize))
        let reader = ArtifactSharingOverride(base: RuleTestReadOnlyFileSystem(root: home), sharing: [
            rlib.resolvingSymlinksInPath().path: .known(FileStorageSharing(
                privateBytes: 0, allocatedDataBytes: rlibBytes, cloneID: 7, cloneReferenceCount: 2, mayShareBlocks: true)),
        ])
        let scanner = ProjectArtifactScanner(fileSystem: reader, home: home)
        let row = try XCTUnwrap(scanner.scanSynchronously(roots: [project]).rows.first)
        XCTAssertNil(row.blockedReason)
        XCTAssertEqual(reader.reads.sorted(), ["target/CACHEDIR.TAG", "target/debug/app.rlib", "target/generated.bin"]
            .map { project.appendingPathComponent($0).resolvingSymlinksInPath().path }.sorted(),
            "Regular files only, each once")
        let estimate = try XCTUnwrap(row.candidate.reclaimableEstimate)
        XCTAssertEqual(estimate.cloneSharedBytes, rlibBytes)
        XCTAssertEqual(estimate.cloneGroupsReachingOutside.map(\.members), [1])
        XCTAssertEqual(estimate.reclaimableBytes(ofAllocated: row.candidate.estimatedSizeBytes),
                       row.candidate.estimatedSizeBytes - rlibBytes)

        reader.forgetReads()
        let requirement = ProjectArtifactRequirement.catalog.first { $0.ecosystem == "Cargo" }!
        XCTAssertNil(scanner.assess(artifact: project.appendingPathComponent("target"), project: project,
                                    requirement: requirement).reason)
        XCTAssertEqual(reader.reads, [], "The check before the move reads sizes, not sharing")

        try write("target/Cargo.lock", in: project)
        let blocked = try XCTUnwrap(scanner.scanSynchronously(roots: [project]).rows.first)
        XCTAssertNotNil(blocked.blockedReason)
        XCTAssertNil(blocked.candidate.reclaimableEstimate, "A row that is only shown frees nothing")
        let view = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/ProjectArtifactView.swift")
        XCTAssertTrue(view.contains("if let reclaimable = CleanupCandidateRowHint.reclaimable(for: row.candidate) {"))
    }
    func testCrossVolumeOnlyDisplays() throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("target", in: project)
        let scanner = ProjectArtifactScanner(fileSystem: ArtifactMetadataOverride(base: RuleTestReadOnlyFileSystem(root: home), overrideVolumeAt: project.appendingPathComponent("target")), home: home)
        let result = try scanner.scanSynchronously(roots: [project])
        XCTAssertFalse(try XCTUnwrap(result.rows.first).candidate.isSelectable)
        XCTAssertEqual(result.rows.first?.blockedReason, "跨卷目录，仅显示")
    }
    func testGitIgnoreNegationAndTrackedOverride() throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("target", in: project)
        try git(["init", "-q"], in: project)
        XCTAssertEqual(ProjectArtifactGitSafety.check(project: project, artifact: project.appendingPathComponent("target")), .notIgnored)
        try write(".gitignore", in: project, text: "target/\n")
        XCTAssertEqual(ProjectArtifactGitSafety.check(project: project, artifact: project.appendingPathComponent("target")), .ignored)
        XCTAssertTrue(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable)
        try git(["add", "-f", "target/generated.bin"], in: project)
        XCTAssertEqual(ProjectArtifactGitSafety.check(project: project, artifact: project.appendingPathComponent("target")), .tracked)
        XCTAssertFalse(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable)
        try git(["rm", "--cached", "-q", "target/generated.bin"], in: project)
        try write(".gitignore", in: project, text: "target/\n!target/\n")
        XCTAssertEqual(ProjectArtifactGitSafety.check(project: project, artifact: project.appendingPathComponent("target")), .notIgnored)
    }
    func testGitRepositoryAboveChosenFolderAndNestedIgnoreRules() throws {
        let (home, parent) = try fixture()
        try git(["init", "-q"], in: parent)
        let project = parent.appendingPathComponent("nested")
        try write("Cargo.toml", in: project); try artifact("target", in: project)
        try write(".gitignore", in: project, text: "target/\n")
        XCTAssertTrue(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable)
    }
    func testDepthEntryProjectAndMeasurementLimits() throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("target", in: project); try write("src/nested/file", in: project)
        for limits in [ProjectArtifactScanLimits(maximumDepth: 0), .init(maximumEntries: 1), .init(maximumProjects: 0), .init(maximumArtifactEntries: 1), .init(maximumArtifactDepth: 0)] {
            let result = try scan(home: home, project: project, limits: limits)
            XCTAssertTrue(result.limited || result.rows.allSatisfy { !$0.candidate.isSelectable })
            XCTAssertTrue(result.inactiveIDs(days: 1, now: .distantFuture).isEmpty)
        }
    }
    func testCancellationStopsDetachedWorker() async throws {
        let (home, project) = try fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProjectArtifactScanner(fileSystem: RuleTestReadOnlyFileSystem(root: home), home: home).scan(roots: [project])
        }
        do { _ = try await task.value; XCTFail("Cancelled scan must throw") }
        catch is CancellationError {} // cancellation is an asserted result
    }
    func testInactiveSelectionUsesProjectSourceTimeAndAdjustableDays() throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("target", in: project)
        let old = Date().addingTimeInterval(-45 * 86_400)
        for relative in ["", "Cargo.toml", "target", "target/generated.bin", "target/CACHEDIR.TAG"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: project.appendingPathComponent(relative).path)
        }
        let result = try scan(home: home, project: project)
        XCTAssertEqual(result.inactiveIDs().count, 1)
        XCTAssertTrue(result.inactiveIDs(days: 60).isEmpty)
        try write("target/generated.bin", in: project, text: "new build output")
        XCTAssertTrue(try scan(home: home, project: project).inactiveIDs().isEmpty)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: project.appendingPathComponent("target/generated.bin").path)
        try write("src/main.rs", in: project)
        XCTAssertTrue(try scan(home: home, project: project).inactiveIDs().isEmpty)
    }
    func testNoDefaultHomeScopeAndUserExclusions() throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("target", in: project)
        let scanner = ProjectArtifactScanner(fileSystem: RuleTestReadOnlyFileSystem(root: home), home: home, excludedURLs: [project.appendingPathComponent("target")])
        XCTAssertTrue(try scanner.scanSynchronously(roots: []).rows.isEmpty)
        XCTAssertTrue(try scanner.scanSynchronously(roots: [home]).rows.isEmpty)
        let ignored = try scanner.scanSynchronously(roots: [project])
        XCTAssertTrue(ignored.rows.isEmpty, "D207＋旧值：排除项仍列成不可选行；现在不列出")
        XCTAssertEqual(ignored.session.metrics.ignoredItemCount, 1)
    }
    func testFingerprintIncludesRebuildRequirementAndReceiptRevision() async throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("target", in: project)
        let result = try scan(home: home, project: project)
        let row = try XCTUnwrap(result.rows.first)
        var selection = CleanupSelection()
        selection.setCandidate(row.id, selected: true, in: result.session)
        let plan = try CleanPlanBuilder.makePlan(session: result.session, selection: selection, activeRules: result.rules, disposition: .trash)
        XCTAssertEqual(plan.rulesProvenance, result.rules.effectiveProvenance)
        XCTAssertEqual(plan.items.first?.ruleRevision, 1)
        var changed = result.rules.rules[0]
        changed.projectArtifact = .init(ecosystem: "Cargo", manifest: "Cargo.toml", relativeArtifact: "target", rebuildCommand: "changed", evidenceURL: row.requirement.evidenceURL)
        XCTAssertNotEqual(result.rules.effectiveProvenance, CleanupRuleSet(schemaVersion: 2, rulesVersion: result.rules.rulesVersion, rules: [changed]).effectiveProvenance)
        let mover = ArtifactRejectingMover()
        let executor = SafeCleanupExecutor(metadataReader: RuleTestReadOnlyFileSystem(root: home), mover: mover, coordinator: HeavyWorkCoordinator())
        let context = CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: result.session.id, activeRules: result.rules, userHomeURL: home, excludedURLs: [], approvedPlanItemIDs: Set(plan.items.map(\.id)))
        let preflight = await executor.preflight(plan: plan, context: context)
        XCTAssertTrue(preflight.isConfirmable, "\(preflight)")
        let report = await executor.execute(plan: plan, context: context, progress: { _ in })
        XCTAssertEqual(report.rulesProvenance, result.rules.effectiveProvenance)
        XCTAssertEqual(report.items.first?.ruleRevision, 1)
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(CleanReport.self, from: encoded)
        XCTAssertEqual(decoded.rulesProvenance, result.rules.effectiveProvenance)
        XCTAssertEqual(decoded.items.first?.ruleRevision, 1)
        XCTAssertEqual(report.summary.failedItemCount, 1, "Injected mover refuses actual filesystem writes")
    }
    func testPreflightRejectsChangedManifestTrackedAndProtectedContent() async throws {
        for mutation in ["manifest", "tracked", "protected", "venv", "write"] {
            let (home, project) = try fixture()
            let python = mutation == "venv"
            try write(python ? "requirements.txt" : "Cargo.toml", in: project)
            let artifactName = python ? ".venv" : "target"
            try artifact(artifactName, in: project)
            if python { try write(".venv/pyvenv.cfg", in: project) }
            try git(["init", "-q"], in: project)
            try write(".gitignore", in: project, text: artifactName + "/\n")
            let result = try scan(home: home, project: project)
            var selection = CleanupSelection()
            selection.setCandidate(try XCTUnwrap(result.rows.first).id, selected: true, in: result.session)
            let plan = try CleanPlanBuilder.makePlan(session: result.session, selection: selection, activeRules: result.rules, disposition: .trash)
            switch mutation {
            case "manifest": try FileManager.default.removeItem(at: project.appendingPathComponent("Cargo.toml"))
            case "tracked": try git(["add", "-f", "target/generated.bin"], in: project)
            case "protected": try write("target/.git/HEAD", in: project)
            case "venv": try FileManager.default.removeItem(at: project.appendingPathComponent(".venv/pyvenv.cfg"))
            default: try write("target/new.bin", in: project)
            }
            let executor = SafeCleanupExecutor(metadataReader: RuleTestReadOnlyFileSystem(root: home), mover: ArtifactRejectingMover(), coordinator: HeavyWorkCoordinator())
            let context = CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: result.session.id, activeRules: result.rules, userHomeURL: home, excludedURLs: [], approvedPlanItemIDs: nil)
            let preflight = await executor.preflight(plan: plan, context: context)
            XCTAssertEqual(preflight.readyCount, 0, mutation)
            XCTAssertNil(preflight.failure, mutation)
            XCTAssertEqual(preflight.items.map(\.status), [.skipped(mutation == "write" ? .candidateBecameActive : .rulesChanged)], mutation)
        }
    }
    func testProtectionAddedDuringDurableIntentStopsFinalMove() async throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("target", in: project)
        let result = try scan(home: home, project: project)
        var selection = CleanupSelection()
        selection.setCandidate(try XCTUnwrap(result.rows.first).id, selected: true, in: result.session)
        let plan = try CleanPlanBuilder.makePlan(session: result.session, selection: selection, activeRules: result.rules, disposition: .trash)
        let counter = ArtifactIntentCounter()
        let executor = SafeCleanupExecutor(metadataReader: RuleTestReadOnlyFileSystem(root: home), mover: ArtifactRejectingMover(), coordinator: HeavyWorkCoordinator(), persistReport: { _, _ in
            if counter.increment() == 2 {
                let marker = project.appendingPathComponent("target/.git")
                try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
            }
        })
        let context = CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: result.session.id, activeRules: result.rules, userHomeURL: home, excludedURLs: [], approvedPlanItemIDs: Set(plan.items.map(\.id)))
        let preflight = await executor.preflight(plan: plan, context: context)
        XCTAssertTrue(preflight.isConfirmable, "\(preflight)")
        let report = await executor.execute(plan: plan, context: context, progress: { _ in })
        XCTAssertEqual(report.summary.movedItemCount, 0)
        XCTAssertEqual(report.summary.skippedItemCount, 1)
        XCTAssertEqual(report.summary.failedItemCount, 0, "Mover must not be invoked after protected content appears")
        XCTAssertEqual(report.rulesProvenance, result.rules.effectiveProvenance)
    }
    func testBuildSubcommandsDoNotConfirmHandMaintainedResources() throws {
        for command in ["vite build", "ng build", "electron-vite build && electron-builder", "gulp build", "nx build"] {
            let (home, project) = try fixture()
            try write("package.json", in: project, text: "{\"scripts\":{\"build\":\"\(command)\"}}")
            for name in ["icon.icns", "entitlements.mac.plist", "notarize.js"] { try write("build/" + name, in: project) }
            XCTAssertTrue(try scan(home: home, project: project).rows.isEmpty, command)
        }
        let (home, project) = try fixture()
        try write("package.json", in: project, text: #"{"scripts":{"build":"tool --output build"}}"#)
        try write("build/notarize.js", in: project)
        XCTAssertFalse(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable)
    }

    func testNodeOutputRequiresConfigOrDefaultProductSignature() throws {
        let (home, project) = try fixture()
        try write("package.json", in: project, text: #"{"scripts":{"build":"vite build"}}"#)
        try artifact("dist", in: project); try artifact("build", in: project)
        XCTAssertTrue(try scan(home: home, project: project).rows.isEmpty)
        try write("dist/index.html", in: project); try write("dist/assets/app.js", in: project)
        XCTAssertEqual(try scan(home: home, project: project).rows.map { $0.requirement.relativeArtifact }, ["dist"])
        try write("vite.config.ts", in: project, text: "export default { build: { outDir: 'build' } }")
        XCTAssertEqual(Set(try scan(home: home, project: project).rows.map { $0.requirement.relativeArtifact }), ["build"])
        try write("vite.config.ts", in: project, text: "// outDir: 'build'\nexport default {}")
        XCTAssertTrue(try scan(home: home, project: project).rows.isEmpty)
    }

    func testInstalledPayloadRootsAndAncestorsAreNeverProjects() throws {
        for relative in ["node_modules/foo", "Node_Modules/foo", "lib/site-packages/foo", ".vscode/extensions/foo", ".cursor/extensions/foo", "custom-env/lib/pkg"] {
            let (home, project) = try fixture()
            let package = project.appendingPathComponent(relative)
            try write("package.json", in: package, text: #"{"scripts":{"build":"tsup src --out-dir dist"}}"#)
            try write("dist/index.js", in: package); try artifact("node_modules", in: package)
            if relative.hasPrefix("custom-env") { try write("custom-env/pyvenv.cfg", in: project) }
            let result = try scan(home: home, project: package)
            XCTAssertTrue(result.rows.isEmpty, relative)
            XCTAssertEqual(result.scopeWarnings.count, 1, relative)
        }
        let (home, project) = try fixture()
        try write("package.json", in: project, text: "{}")
        try write("node_modules/foo/package.json", in: project, text: #"{"scripts":{"build":"tsup --out-dir dist"}}"#)
        try artifact("node_modules/foo/dist", in: project)
        XCTAssertEqual(try scan(home: home, project: project).rows.map { $0.requirement.relativeArtifact }, ["node_modules"])
        XCTAssertTrue(try scan(home: home, project: project.appendingPathComponent("node_modules")).rows.isEmpty)
    }

    func testRealisticDependencyAndGeneratedArtifactShapesAreSelectable() async throws {
        for ecosystem in ["npm", "Python", "Swift", "Cargo", "dist"] {
            let (home, project) = try fixture()
            let artifactName: String
            switch ecosystem {
            case "npm":
                artifactName = "node_modules"
                try write("package.json", in: project, text: "{}")
                try write("node_modules/.package-lock.json", in: project)
                try write("node_modules/tool/bin/run.js", in: project)
                try write("node_modules/tool/package-lock.json", in: project)
                try TestFileSystem.createDirectory(at: project.appendingPathComponent("node_modules/.bin"))
                try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("node_modules/.bin/tool").path, withDestinationPath: "../tool/bin/run.js")
            case "Python":
                artifactName = ".venv"
                try write("requirements.txt", in: project); try write(".venv/pyvenv.cfg", in: project)
                try write("toolchain/bin/python3", in: project)
                try write(".venv/lib/python3.9/site-packages/pip/_vendor/certifi/cacert.pem", in: project)
                try TestFileSystem.createDirectory(at: project.appendingPathComponent(".venv/bin"))
                try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent(".venv/bin/python").path, withDestinationPath: project.appendingPathComponent("toolchain/bin/python3").path)
            case "Swift":
                artifactName = ".build"
                try write("Package.swift", in: project); try write(".build/workspace-state.json", in: project); try write(".build/manifest.db", in: project)
                try write(".build/arm64-apple-macosx/debug/module.swift", in: project)
                try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent(".build/debug").path, withDestinationPath: "arm64-apple-macosx/debug")
            case "Cargo":
                artifactName = "target"
                try write("Cargo.toml", in: project); try write("target/CACHEDIR.TAG", in: project); try write("target/debug/build/pkg/out/generated.rs", in: project)
            default:
                artifactName = "dist"
                try write("package.json", in: project, text: #"{"scripts":{"build":"tsup --out-dir dist"}}"#)
                try artifact("dist", in: project); try write("dist/index.js", in: project); try write("dist/index.d.ts", in: project)
            }
            let result = try scan(home: home, project: project)
            let row = try XCTUnwrap(result.rows.first)
            XCTAssertEqual(row.requirement.relativeArtifact, artifactName)
            XCTAssertTrue(row.candidate.isSelectable, "\(ecosystem): \(row.blockedReason ?? "")")
            var selection = CleanupSelection()
            selection.setCandidate(row.id, selected: true, in: result.session)
            let plan = try CleanPlanBuilder.makePlan(session: result.session, selection: selection, activeRules: result.rules, disposition: .trash)
            let executor = SafeCleanupExecutor(metadataReader: RuleTestReadOnlyFileSystem(root: home), mover: ArtifactRejectingMover(), coordinator: HeavyWorkCoordinator())
            let context = CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: result.session.id, activeRules: result.rules, userHomeURL: home, excludedURLs: [], approvedPlanItemIDs: nil)
            let preflight = await executor.preflight(plan: plan, context: context)
            XCTAssertEqual(preflight.readyCount, 1, "\(ecosystem): \(preflight)")
            try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent(artifactName + "/outside").path, withDestinationPath: "../../personal.txt")
            XCTAssertFalse(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable, ecosystem)
        }
    }

    func testArtifactLimitDoesNotBlockOtherRows() throws {
        let (home, project) = try fixture()
        try write("package.json", in: project, text: #"{"scripts":{"build":"tool --outDir dist"}}"#)
        try artifact("node_modules", in: project); try write("node_modules/pkg/extra.js", in: project)
        try artifact("dist", in: project)
        try write(".gitignore", in: project, text: "node_modules/\ndist/\n")
        let result = try scan(home: home, project: project, limits: .init(maximumArtifactEntries: 2))
        let limited = try XCTUnwrap(result.rows.first { $0.requirement.relativeArtifact == "node_modules" })
        XCTAssertFalse(limited.candidate.isSelectable)
        XCTAssertEqual(limited.blockedReason, "产物测量达到上限，仅显示")
        XCTAssertTrue(try XCTUnwrap(result.rows.first { $0.requirement.relativeArtifact == "dist" }).candidate.isSelectable)
        XCTAssertEqual(result.inactiveIDs(days: 1, now: .distantFuture).count, 1)
    }

    func testProjectLimitNeverAdmitsAnExtraProject() throws {
        let (home, root) = try fixture()
        for name in ["one", "two"] { try write(name + "/Cargo.toml", in: root); try artifact(name + "/target", in: root) }
        let result = try scan(home: home, project: root, limits: .init(maximumProjects: 1))
        XCTAssertEqual(Set(result.rows.map(\.project)).count, 1)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertTrue(result.limited)
    }

    func testMonorepoActivityPreventsRootInactiveSelection() throws {
        let (home, root) = try fixture()
        try write("package.json", in: root, text: "{}"); try artifact("node_modules", in: root)
        try write("packages/app/package.json", in: root, text: "{}")
        try write("packages/app/src/index.js", in: root)
        let old = Date().addingTimeInterval(-90 * 86_400)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
        var paths = [root.path]
        while let relative = enumerator.nextObject() as? String { paths.append(root.appendingPathComponent(relative).path) }
        for path in paths.reversed() { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path) }
        try write("packages/app/src/index.js", in: root, text: "edited today")
        let result = try scan(home: home, project: root)
        let row = try XCTUnwrap(result.rows.first { $0.project == root })
        XCTAssertFalse(result.inactiveIDs().contains(row.id))
        XCTAssertGreaterThan(try XCTUnwrap(row.projectModifiedAt), old)
    }

    func testGitGlobalExcludesAndUnavailableToolchain() throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("target", in: project)
        try git(["init", "-q"], in: project)
        try write(".gitconfig", in: home, text: "[core]\n\texcludesFile = ~/.global-ignore\n")
        try write(".global-ignore", in: home, text: "target/\n")
        let target = project.appendingPathComponent("target")
        XCTAssertEqual(ProjectArtifactGitSafety.check(project: project, artifact: target, configurationHome: home), .ignored)
        XCTAssertEqual(ProjectArtifactGitSafety.check(project: project, artifact: target, toolchainAvailable: false, configurationHome: home), .unknown)
    }

    func testLockEvidenceIsVisibleAndChangesFingerprint() throws {
        let (home, project) = try fixture()
        try write("package.json", in: project, text: "{}"); try artifact("node_modules", in: project)
        let before = try scan(home: home, project: project)
        XCTAssertTrue(try XCTUnwrap(before.rows.first?.requirement.lockEvidence).contains("重建可能取不同版本"))
        XCTAssertTrue(try XCTUnwrap(before.rows.first).candidate.isSelectable)
        try write("package-lock.json", in: project)
        let after = try scan(home: home, project: project)
        XCTAssertTrue(try XCTUnwrap(after.rows.first?.requirement.lockEvidence).contains("已确认锁文件：package-lock.json"))
        XCTAssertNotEqual(before.rules.effectiveProvenance, after.rules.effectiveProvenance)
    }

    func testInheritedPythonCacheUsesNearestRepository() throws {
        let (home, project) = try fixture()
        try write("requirements.txt", in: project)
        try git(["init", "-q"], in: project); try write(".gitignore", in: project, text: "__pycache__/\n")
        let nested = project.appendingPathComponent("nested")
        try write("__pycache__/tracked.pyc", in: nested); try git(["init", "-q"], in: nested)
        try git(["add", "__pycache__/tracked.pyc"], in: nested)
        let row = try XCTUnwrap(scan(home: home, project: project).rows.first)
        XCTAssertEqual(row.blockedReason, "Git 已跟踪产物内容，不可选")
        XCTAssertFalse(row.candidate.isSelectable)
    }

    func testLegacyCloudRootsAndCaseInsensitiveDiscovery() throws {
        let (home, project) = try fixture()
        for name in ["Dropbox", "Google Drive", "OneDrive"] {
            let root = home.appendingPathComponent(name)
            let result = try scan(home: home, project: root)
            XCTAssertTrue(result.rows.isEmpty)
            XCTAssertEqual(result.scopeWarnings.count, 1)
        }
        for name in ["Node_Modules", ".GIT", ".ENV.production"] {
            try write(name + "/package.json", in: project, text: "{}"); try artifact(name + "/node_modules", in: project)
        }
        let result = try scan(home: home, project: project)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertTrue(result.scopeWarnings.isEmpty, "Discovery must not enter installed containers at all")
    }

    func testInternalProtectedLinksStayReadOnly() throws {
        for name in [".git", ".env.production"] {
            let (home, project) = try fixture()
            try write("package.json", in: project, text: "{}"); try artifact("node_modules", in: project)
            try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("node_modules/" + name).path, withDestinationPath: "generated.bin")
            let row = try XCTUnwrap(scan(home: home, project: project).rows.first)
            XCTAssertFalse(row.candidate.isSelectable)
            XCTAssertTrue(row.blockedReason?.contains("保护标记") == true)
        }
    }

    func testDiscoveryLimitOnlyRemovesAffectedProjectActivityEvidence() throws {
        let (home, project) = try fixture()
        try write("one/Cargo.toml", in: project); try artifact("one/target", in: project)
        try write("one/src/nested/file.rs", in: project)
        try write("two/Cargo.toml", in: project); try artifact("two/target", in: project)
        let result = try scan(home: home, project: project, limits: .init(maximumDepth: 1))
        let incomplete = try XCTUnwrap(result.rows.first { $0.project.lastPathComponent == "one" })
        let complete = try XCTUnwrap(result.rows.first { $0.project.lastPathComponent == "two" })
        XCTAssertTrue(incomplete.candidate.isSelectable)
        XCTAssertNil(incomplete.projectModifiedAt)
        XCTAssertTrue(complete.candidate.isSelectable)
        XCTAssertEqual(result.inactiveIDs(days: 1, now: .distantFuture), [complete.id])
    }

    func testCancellationDuringDiscoveryStopsWorker() async throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("target", in: project)
        let started = expectation(description: "Discovery read entered")
        let gate = ArtifactReadGate(started: started)
        let scanner = ProjectArtifactScanner(fileSystem: ArtifactGatedFileSystem(base: RuleTestReadOnlyFileSystem(root: home), gate: gate), home: home)
        let task = Task { try await scanner.scan(roots: [project]) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel(); gate.release.signal()
        do { _ = try await task.value; XCTFail("Mid-discovery cancellation must throw") }
        catch is CancellationError {}
    }

    func testCancellationDuringGitProcessWaitStopsProcess() async throws {
        let started = expectation(description: "Read-only process started")
        let process = Process()
        let task = Task.detached {
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            started.fulfill()
            return ProjectArtifactGitSafety.waitForExit(process)
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        let finished = try await task.value
        XCTAssertFalse(finished)
        XCTAssertFalse(process.isRunning)
    }

    func testCloudMetadataAndGitUnknownAreReadOnly() throws {
        let (home, project) = try fixture()
        try write("Cargo.toml", in: project); try artifact("target", in: project)
        let reader = ArtifactMetadataOverride(base: RuleTestReadOnlyFileSystem(root: home), overrideVolumeAt: nil, overrideCloudAt: project.appendingPathComponent("target"))
        let result = try ProjectArtifactScanner(fileSystem: reader, home: home).scanSynchronously(roots: [project])
        XCTAssertFalse(try XCTUnwrap(result.rows.first).candidate.isSelectable)
        XCTAssertEqual(result.rows.first?.blockedReason, "云盘位置，仅显示")
        try write(".git", in: project, text: "gitdir: missing-repository")
        let unknown = try XCTUnwrap(scan(home: home, project: project).rows.first)
        XCTAssertFalse(unknown.candidate.isSelectable)
        XCTAssertEqual(unknown.blockedReason, "无法核对 Git 状态，仅显示")
    }

    func testPreflightRejectsChangedLockEvidence() async throws {
        let (home, project) = try fixture()
        try write("package.json", in: project, text: "{}"); try artifact("node_modules", in: project)
        let result = try scan(home: home, project: project)
        var selection = CleanupSelection()
        selection.setCandidate(try XCTUnwrap(result.rows.first).id, selected: true, in: result.session)
        let plan = try CleanPlanBuilder.makePlan(session: result.session, selection: selection, activeRules: result.rules, disposition: .trash)
        try write("package-lock.json", in: project)
        let executor = SafeCleanupExecutor(metadataReader: RuleTestReadOnlyFileSystem(root: home), mover: ArtifactRejectingMover(), coordinator: HeavyWorkCoordinator())
        let context = CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: result.session.id, activeRules: result.rules, userHomeURL: home, excludedURLs: [], approvedPlanItemIDs: nil)
        let preflight = await executor.preflight(plan: plan, context: context)
        XCTAssertNil(preflight.failure)
        XCTAssertEqual(preflight.items.map(\.status), [.skipped(.rulesChanged)])
    }

    // Review-round-2 probe D, rewritten to require discovery beneath generic names.
    func testProjectUnderGenericArtifactAncestorIsScanned() throws {
        let (home, _) = try fixture()
        for parent in ["build", "target", "dist", "vendor", "Bundle", ".build", "venv"] {
            let root = home.appendingPathComponent("Other/" + parent)
            let project = root.appendingPathComponent("app")
            try write("Cargo.toml", in: project); try artifact("target", in: project)
            for selectedRoot in [project, root, home.appendingPathComponent("Other")] {
                let result = try scan(home: home, project: selectedRoot)
                let row = try XCTUnwrap(result.rows.first { PathSafety.lexicalPath($0.project.path) == PathSafety.lexicalPath(project.path) })
                XCTAssertTrue(row.candidate.isSelectable, parent)
                XCTAssertTrue(result.scopeWarnings.isEmpty, parent)
            }
        }
    }

    // Review-round-2 probe A: a manifest and handwritten dependency contents are insufficient.
    func testNonGitHandwrittenArtifactsRequireGeneratedMarkers() throws {
        let (home, project) = try fixture()
        try write("package.json", in: project, text: "{}")
        try write("node_modules/my-notes/notes.md", in: project)
        try write("node_modules/my-notes/data.sqlite", in: project)
        try write("node_modules/my-notes/package-lock.json", in: project)
        try write("Cargo.toml", in: project); try write("target/handwritten/main.rs", in: project)
        try write("Package.swift", in: project); try write(".build/MyTool/main.swift", in: project)
        let blocked = try scan(home: home, project: project)
        XCTAssertEqual(blocked.rows.count, 3)
        for row in blocked.rows {
            XCTAssertFalse(row.candidate.isSelectable)
            XCTAssertEqual(row.blockedReason, "非 Git 项目缺少工具生成标记，无法确认可再生产物，仅显示")
        }
        for marker in ["node_modules/.package-lock.json", "target/CACHEDIR.TAG", ".build/workspace-state.json"] { try write(marker, in: project) }
        XCTAssertTrue(try scan(home: home, project: project).rows.allSatisfy { $0.candidate.isSelectable })
        try git(["init", "-q"], in: project)
        XCTAssertTrue(try scan(home: home, project: project).rows.allSatisfy { $0.blockedReason == "Git 未忽略此产物，仅显示" })
        try write(".gitignore", in: project, text: "node_modules/\ntarget/\n.build/\n")
        for marker in ["node_modules/.package-lock.json", "target/CACHEDIR.TAG", ".build/workspace-state.json"] { try FileManager.default.removeItem(at: project.appendingPathComponent(marker)) }
        XCTAssertTrue(try scan(home: home, project: project).rows.allSatisfy { $0.candidate.isSelectable })
    }

    // Review-round-2 probe C: every interpreter path is fake and owned by this test.
    func testVenvInterpreterUsesConfiguredHomeAcrossToolchains() throws {
        let (home, _) = try fixture()
        for (index, shape) in ["Applications/Xcode.app/Contents/Developer/usr/bin", "opt/homebrew/opt/python@3.14/bin", ".pyenv/versions/3.12.1/bin", ".local/share/uv/python/cpython-3.12/bin"].enumerated() {
            let project = home.appendingPathComponent("Projects/venv\(index)")
            let toolHome = home.appendingPathComponent("Fake/" + shape)
            try write("python3.14", in: toolHome)
            try write("requirements.txt", in: project)
            try write(".venv/pyvenv.cfg", in: project, text: "home = \(toolHome.path)\n")
            try TestFileSystem.createDirectory(at: project.appendingPathComponent(".venv/bin"))
            let link = project.appendingPathComponent(".venv/bin/python3")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: toolHome.appendingPathComponent("python3.14"))
            XCTAssertTrue(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable, shape)
            let alias = home.appendingPathComponent("alias\(index)")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: toolHome)
            try write(".venv/pyvenv.cfg", in: project, text: "home = \(alias.path)\n")
            XCTAssertTrue(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable, "canonical home")
            for config in ["missing", "home = relative/bin", "home = /", "home = \(home.appendingPathComponent("wrong").path)", "home = \(toolHome.path)\nhome = \(toolHome.path)"] {
                try write(".venv/pyvenv.cfg", in: project, text: config)
                XCTAssertFalse(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable, config)
            }
            try write(".venv/pyvenv.cfg", in: project, text: "home = \(toolHome.path)\n")
            try FileManager.default.removeItem(at: link)
            try write("sh", in: toolHome)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: toolHome.appendingPathComponent("sh"))
            XCTAssertFalse(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable)
        }
    }

    func testAlternativeGeneratedMarkersAndBytecodeOnlyCache() throws {
        for (manifest, directory, marker) in [("package.json", "node_modules", ".yarn-state.yml"), ("package.json", "node_modules", ".modules.yaml"), ("Package.swift", ".build", "debug.yaml"), ("composer.json", "vendor", "composer/installed.json"), ("pubspec.yaml", ".dart_tool", "package_config.json")] {
            let (home, project) = try fixture()
            try write(manifest, in: project, text: "{}")
            try write(directory + "/generated.bin", in: project)
            XCTAssertFalse(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable)
            try write(directory + "/" + marker, in: project)
            XCTAssertTrue(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable, marker)
            try FileManager.default.removeItem(at: project.appendingPathComponent(directory + "/" + marker))
            try write("elsewhere/marker", in: project)
            try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(directory + "/" + marker), withDestinationURL: project.appendingPathComponent("elsewhere/marker"))
            XCTAssertFalse(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable, "linked marker")
        }
        let (home, project) = try fixture()
        try write("requirements.txt", in: project); try write("src/__pycache__/a.pyc", in: project)
        XCTAssertTrue(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable)
        try write("src/__pycache__/notes.md", in: project)
        XCTAssertFalse(try XCTUnwrap(scan(home: home, project: project).rows.first).candidate.isSelectable)
    }

    func testInstalledVendorRequiresInstallationEvidence() throws {
        for (container, marker) in [("vendor", "composer/installed.json"), ("vendor/bundle", "ruby/3.4.0/specifications/example.gemspec")] {
            let (home, parent) = try fixture()
            let root = parent.appendingPathComponent(container)
            let project = root.appendingPathComponent("app")
            try write("Cargo.toml", in: project); try artifact("target", in: project)
            XCTAssertEqual(try scan(home: home, project: project).rows.count, 1)
            if container == "vendor/bundle" {
                try write(".bundle/config", in: root, text: "BUNDLE_PATH: vendor/bundle")
                XCTAssertEqual(try scan(home: home, project: project).rows.count, 1, "configuration alone is not installed payload")
            }
            try write(marker, in: root)
            for selected in [root, project] {
                let result = try scan(home: home, project: selected)
                XCTAssertTrue(result.rows.isEmpty)
                XCTAssertEqual(result.scopeWarnings.count, 1)
            }
        }
    }

    func testNonGitMarkerRemovalIsRejectedAtPreflight() async throws {
        let (home, project) = try fixture()
        try write("package.json", in: project, text: "{}"); try artifact("node_modules", in: project)
        let result = try scan(home: home, project: project)
        var selection = CleanupSelection()
        selection.setCandidate(try XCTUnwrap(result.rows.first).id, selected: true, in: result.session)
        let plan = try CleanPlanBuilder.makePlan(session: result.session, selection: selection, activeRules: result.rules, disposition: .trash)
        try FileManager.default.removeItem(at: project.appendingPathComponent("node_modules/.package-lock.json"))
        let executor = SafeCleanupExecutor(metadataReader: RuleTestReadOnlyFileSystem(root: home), mover: ArtifactRejectingMover(), coordinator: HeavyWorkCoordinator())
        let context = CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: result.session.id, activeRules: result.rules, userHomeURL: home, excludedURLs: [], approvedPlanItemIDs: nil)
        let preflight = await executor.preflight(plan: plan, context: context)
        XCTAssertNil(preflight.failure)
        XCTAssertEqual(preflight.items.map(\.status), [.skipped(.rulesChanged)])
    }

    private func git(_ arguments: [String], in root: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

/// D104 G1: answers sharing for chosen paths and counts every read.
private final class ArtifactSharingOverride: ReadOnlyFileSystem, @unchecked Sendable {
    let base: any ReadOnlyFileSystem
    let sharing: [String: FileStorageSharing.Reading]
    private let lock = NSLock()
    private var readPaths: [String] = []
    init(base: any ReadOnlyFileSystem, sharing: [String: FileStorageSharing.Reading]) {
        self.base = base
        self.sharing = sharing
    }
    var reads: [String] { lock.withLock { readPaths } }
    func forgetReads() { lock.withLock { readPaths = [] } }
    func snapshot(at url: URL) throws -> FileSnapshot { try base.snapshot(at: url) }
    func aggregateSnapshot(at url: URL) throws -> FileSnapshot { try base.aggregateSnapshot(at: url) }
    func children(of directory: URL) throws -> [URL] { try base.children(of: directory) }
    /// Paths compare resolved: the temporary home is /var/… and the scanner
    /// reads what it lists under /private/var/….
    func storageSharing(at url: URL) -> FileStorageSharing.Reading {
        let path = url.resolvingSymlinksInPath().path
        lock.withLock { readPaths.append(path) }
        return sharing[path] ?? .notReported
    }
}
private struct ArtifactMetadataOverride: ReadOnlyFileSystem {
    let base: any ReadOnlyFileSystem
    let overrideVolumeAt: URL?
    var overrideCloudAt: URL? = nil
    func snapshot(at url: URL) throws -> FileSnapshot {
        let original = try base.snapshot(at: url)
        guard url == overrideVolumeAt || url == overrideCloudAt else { return original }
        return .init(identity: original.identity, standardizedPath: original.standardizedPath, volumeIdentifier: url == overrideVolumeAt ? "different-volume" : original.volumeIdentifier,
            logicalSizeBytes: original.logicalSizeBytes, allocatedSizeBytes: original.allocatedSizeBytes, modificationTimeNanoseconds: original.modificationTimeNanoseconds,
            isWritableVolume: original.isWritableVolume, isCloudItem: original.isCloudItem || url == overrideCloudAt, isCloudPlaceholder: original.isCloudPlaceholder, hasSymbolicLinkComponent: original.hasSymbolicLinkComponent)
    }
    func children(of directory: URL) throws -> [URL] { try base.children(of: directory) }
}
private struct ArtifactRejectingMover: CleanupMoving {
    struct Refused: Error {}
    func moveToTrash(_ url: URL) async throws -> URL { throw Refused() }
    func moveToQuarantine(_ url: URL, planID: CleanPlanID, itemID: UUID) async throws -> URL { throw Refused() }
}

private final class ArtifactIntentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private final class ArtifactReadGate: @unchecked Sendable {
    let started: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    init(started: XCTestExpectation) { self.started = started }
    func waitOnce() throws {
        lock.lock(); let first = !entered; entered = true; lock.unlock()
        guard first else { return }
        started.fulfill()
        guard release.wait(timeout: .now() + 30) == .success else { throw CleanupFileSystemError.unreadable }
        try Task.checkCancellation()
    }
}
private struct ArtifactGatedFileSystem: ReadOnlyFileSystem {
    let base: any ReadOnlyFileSystem
    let gate: ArtifactReadGate
    func snapshot(at url: URL) throws -> FileSnapshot { try base.snapshot(at: url) }
    func aggregateSnapshot(at url: URL) throws -> FileSnapshot { try base.aggregateSnapshot(at: url) }
    func children(of directory: URL) throws -> [URL] { try gate.waitOnce(); return try base.children(of: directory) }
}
