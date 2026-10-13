import Foundation

/// D92: these requirements are encoded into D82's effective rule fingerprint.
struct ProjectArtifactRequirement: Codable, Equatable, Sendable {
    let ecosystem: String
    let manifest: String
    let relativeArtifact: String
    let rebuildCommand: String
    let evidenceURL: String
    var revision = 1
    var checkedAt = "2026-10-13"

    var lockEvidence: String? = nil

    static let catalog: [Self] = [
        .init(ecosystem: "npm", manifest: "package.json", relativeArtifact: "node_modules", rebuildCommand: "npm install（有锁文件时优先 npm ci；Yarn/pnpm 项目使用原包管理器）", evidenceURL: "https://docs.npmjs.com/cli/v11/commands/npm-install/"),
        .init(ecosystem: "npm", manifest: "package.json", relativeArtifact: ".next", rebuildCommand: "npm run build（需 next build 脚本）", evidenceURL: "https://nextjs.org/docs/app/api-reference/cli/next"),
        .init(ecosystem: "npm", manifest: "package.json", relativeArtifact: "dist", rebuildCommand: "npm run build（需明确输出 dist 的脚本）", evidenceURL: "https://docs.npmjs.com/cli/v11/using-npm/scripts"),
        .init(ecosystem: "npm", manifest: "package.json", relativeArtifact: "build", rebuildCommand: "npm run build（需明确输出 build 的脚本）", evidenceURL: "https://docs.npmjs.com/cli/v11/using-npm/scripts"),
        .init(ecosystem: "Cargo", manifest: "Cargo.toml", relativeArtifact: "target", rebuildCommand: "cargo build", evidenceURL: "https://doc.rust-lang.org/cargo/reference/build-cache.html"),
        .init(ecosystem: "Python", manifest: "pyproject.toml", relativeArtifact: ".venv", rebuildCommand: "python3 -m venv .venv；按项目清单重新安装依赖", evidenceURL: "https://docs.python.org/3/library/venv.html"),
        .init(ecosystem: "Python", manifest: "pyproject.toml", relativeArtifact: "venv", rebuildCommand: "python3 -m venv venv；按项目清单重新安装依赖", evidenceURL: "https://docs.python.org/3/library/venv.html"),
        .init(ecosystem: "Python", manifest: "pyproject.toml", relativeArtifact: "__pycache__", rebuildCommand: "python3 -m compileall .（或再次运行项目）", evidenceURL: "https://docs.python.org/3/library/compileall.html"),
        .init(ecosystem: "Python", manifest: "pyproject.toml", relativeArtifact: ".pytest_cache", rebuildCommand: "python3 -m pytest", evidenceURL: "https://docs.pytest.org/en/stable/how-to/cache.html"),
        .init(ecosystem: "Python", manifest: "pyproject.toml", relativeArtifact: ".mypy_cache", rebuildCommand: "python3 -m mypy .", evidenceURL: "https://mypy.readthedocs.io/en/stable/command_line.html"),
        .init(ecosystem: "Swift", manifest: "Package.swift", relativeArtifact: ".build", rebuildCommand: "swift build", evidenceURL: "https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/SwiftBuild.md"),
        .init(ecosystem: "Gradle", manifest: "build.gradle", relativeArtifact: "build", rebuildCommand: "./gradlew build（或 gradle build）", evidenceURL: "https://docs.gradle.org/current/userguide/directory_layout.html"),
        .init(ecosystem: "Gradle", manifest: "build.gradle", relativeArtifact: ".gradle", rebuildCommand: "./gradlew build（或 gradle build）", evidenceURL: "https://docs.gradle.org/current/userguide/directory_layout.html"),
        .init(ecosystem: "Maven", manifest: "pom.xml", relativeArtifact: "target", rebuildCommand: "mvn package", evidenceURL: "https://maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html"),
        .init(ecosystem: "Bundler", manifest: "Gemfile", relativeArtifact: "vendor/bundle", rebuildCommand: "bundle install（需 BUNDLE_PATH 指向 vendor/bundle）", evidenceURL: "https://bundler.io/man/bundle-config.1.html"),
        .init(ecosystem: "Composer", manifest: "composer.json", relativeArtifact: "vendor", rebuildCommand: "composer install", evidenceURL: "https://getcomposer.org/doc/01-basic-usage.md"),
        .init(ecosystem: "Dart", manifest: "pubspec.yaml", relativeArtifact: ".dart_tool", rebuildCommand: "dart pub get（Flutter 项目使用 flutter pub get）", evidenceURL: "https://dart.dev/tools/pub/cmd/pub-get"),
        .init(ecosystem: "Dart", manifest: "pubspec.yaml", relativeArtifact: "build", rebuildCommand: "flutter build <原项目目标>；纯 Dart 使用原项目构建命令", evidenceURL: "https://docs.flutter.dev/reference/flutter-cli"),
    ]

    func rule(project: URL, home: URL) -> CleanupRule {
        let relativeRoot = String(PathSafety.lexicalPath(project.path).dropFirst(PathSafety.lexicalPath(home.path).count + 1))
        // The stable path participates in the rule itself. The ID stays readable
        // and unique across projects/manifest variants without a global catalog change.
        let id = "project.\(ecosystem).\(manifest).\(relativeRoot).\(relativeArtifact)"
        return CleanupRule(id: id, selectionPolicyVersion: 1, categoryID: "project-artifacts",
            categoryTitleKey: "项目产物", titleKey: relativeArtifact,
            root: .init(kind: .homeRelative, path: relativeRoot), candidateScope: .immediateChildren,
            maximumDepth: 32, minimumAgeDays: 0, minimumBytes: 0,
            include: .init(entryKinds: [.directory], extensions: [], nameMatcher: .init(mode: .exact, values: [URL(fileURLWithPath: relativeArtifact).lastPathComponent])),
            exclude: .init(relativePrefixes: [], extensions: []), cloudPolicy: .excludeCloudRoots,
            risk: .reviewOnly, recommendation: .optional, defaultSelection: .unselected,
            executionEligibility: .eligibleAfterReview, measurementRequirement: .complete,
            allowsManualSelection: true, action: .moveToTrashAfterReview, requiredClosedBundleIDs: [],
            reasonKey: "project.regenerable", maintenance: .init(source: .developerCatalog, revision: revision,
                checkedAt: checkedAt, impact: "项目依赖或编译产物将移入废纸篓；重建可能需要联网，产物内本地改动不能自动重建", evidenceURLs: [evidenceURL]),
            projectArtifact: self)
    }
}

struct ProjectArtifactRow: Identifiable, Sendable {
    var id: ScanCandidateID { candidate.id }
    let project: URL
    let requirement: ProjectArtifactRequirement
    let candidate: ScanCandidate
    let blockedReason: String?
    let projectModifiedAt: Date?
}

struct ProjectArtifactScanResult: Sendable {
    let rows: [ProjectArtifactRow]
    let rules: CleanupRuleSet
    let session: ScanSession
    let limited: Bool
    var scopeWarnings: [String] = []

    func inactiveIDs(days: Int = 30, now: Date = Date()) -> [ScanCandidateID] {
        guard session.outcome != .cancelled else { return [] }
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400)
        return rows.filter { $0.blockedReason == nil && $0.candidate.isSelectable
            && ($0.projectModifiedAt.map { $0 <= cutoff } ?? false) }.map(\.id)
    }
}
