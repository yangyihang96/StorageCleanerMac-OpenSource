import AppKit
import Darwin
import Foundation

enum CleanupRuleSetLoader {
    static func loadBundled() throws -> CleanupRuleSet {
        let bundledURL = Bundle.main.url(
            forResource: "CleanupRules.v2",
            withExtension: "json"
        )
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/CleanupRules.v2.json")
        let url = bundledURL ?? sourceURL
        let bundledRuleSet = try JSONDecoder().decode(
            CleanupRuleSet.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
        let ruleSet = CleanupRuleSet(
            schemaVersion: bundledRuleSet.schemaVersion,
            rulesVersion: bundledRuleSet.rulesVersion,
            rules: DeveloperToolArtifactCatalog.cleanupRules
                + CleanupCoverageCatalog.cleanupRules
                + bundledRuleSet.rules
        )
        try CleanupRuleValidator.validate(ruleSet)
        try CleanupRuleMaintenanceValidator.validate(ruleSet)
        for rule in bundledRuleSet.rules where rule.maintenance?.source != .json {
            throw CleanupRuleMaintenanceError.sourceMismatch(rule.id)
        }
        return ruleSet
    }
}

enum CleanupRuleValidator {
    private static let maximumDepth = 32
    private static let maximumAgeDays = 3_650
    private static let maximumBytes: Int64 = 1_000_000_000_000_000
    private static let safeRoots = [
        "Library/Caches",
        "Library/Logs",
        "Library/Developer/Xcode/DerivedData",
        "Library/Developer/Xcode/iOS DeviceSupport",
        ".cache",
        ".npm",
        ".pnpm-store",
        ".gradle",
        ".m2",
        ".cargo",
        "Library/pnpm",
        "go/pkg"
    ]
    private static let forbiddenAutomaticRoots = [
        "Library",
        "Applications",
        "Desktop",
        "Documents",
        "Downloads",
        "Movies",
        "Music",
        "Pictures",
        "Library/Mobile Documents",
        "Library/CloudStorage"
    ]

    static func validate(_ ruleSet: CleanupRuleSet) throws {
        guard ruleSet.schemaVersion == 2 else {
            throw CleanupRuleValidationError.unsupportedSchema(ruleSet.schemaVersion)
        }
        guard !ruleSet.rulesVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !ruleSet.rules.isEmpty else {
            throw CleanupRuleValidationError.invalidRulesVersion
        }

        var ruleIDs = Set<String>()
        var automaticRules = [CleanupRule]()
        for rule in ruleSet.rules {
            guard !rule.id.isEmpty, ruleIDs.insert(rule.id).inserted else {
                throw CleanupRuleValidationError.duplicateRuleID(rule.id)
            }
            guard validRoot(rule.root),
                  rule.exclude.relativePrefixes.allSatisfy(validRelativePath),
                  rule.include.extensions.allSatisfy(validExtension),
                  rule.exclude.extensions.allSatisfy(validExtension) else {
                throw CleanupRuleValidationError.invalidRelativePath(ruleID: rule.id)
            }
            guard validNameMatcher(rule.include.nameMatcher),
                  (rule.exclude.namePrefixes ?? []).allSatisfy(validNameValue) else {
                throw CleanupRuleValidationError.invalidNameMatcher(ruleID: rule.id)
            }
            if rule.ownerInference != nil {
                // Only one-row-per-child rules infer an owner per row.
                guard rule.isContainerRule,
                      rule.requiredClosedBundleIDs.isEmpty,
                      rule.action.isExecutable else {
                    throw CleanupRuleValidationError.invalidAttributionMetadata(ruleID: rule.id)
                }
            }
            guard (rule.developerTool == nil) == (rule.developerArtifactKind == nil) else {
                throw CleanupRuleValidationError.invalidDeveloperArtifactMetadata(ruleID: rule.id)
            }
            if let ownerDisplayName = rule.ownerDisplayName {
                guard rule.developerTool == nil,
                      ownerDisplayName.count <= 80,
                      !ownerDisplayName.isEmpty,
                      ownerDisplayName == ownerDisplayName.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ) else {
                    throw CleanupRuleValidationError.invalidAttributionMetadata(
                        ruleID: rule.id
                    )
                }
            }
            guard rule.maximumDepth >= 0,
                  rule.maximumDepth <= maximumDepth,
                  rule.minimumAgeDays >= 0,
                  rule.minimumAgeDays <= maximumAgeDays,
                  rule.minimumBytes >= 0,
                  rule.minimumBytes <= maximumBytes,
                  rule.selectionPolicyVersion > 0 else {
                throw CleanupRuleValidationError.invalidLimit(ruleID: rule.id)
            }
            guard Set(rule.requiredClosedBundleIDs).count == rule.requiredClosedBundleIDs.count,
                  rule.requiredClosedBundleIDs.allSatisfy(validBundleIdentifier),
                  rule.effectiveIncludedBundleIdentifiers.allSatisfy(validBundleIdentifier) else {
                throw CleanupRuleValidationError.invalidBundleIdentifier(ruleID: rule.id)
            }
            if rule.effectiveCandidateScope == .root {
                guard rule.root.kind == .homeRelative,
                      rule.include.entryKinds.contains(.directory),
                      rule.include.extensions.isEmpty,
                      rule.include.nameMatcher.mode == .any,
                      rule.include.nameMatcher.values.isEmpty,
                      rule.exclude.relativePrefixes.isEmpty,
                      rule.exclude.extensions.isEmpty,
                      (rule.exclude.namePrefixes ?? []).isEmpty else {
                    throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
                }
            }
            if rule.effectiveCandidateScope == .descendantAggregate {
                // D19/D24: a read-only aggregate cannot be selected or removed,
                // so no rule may list one (the only user was Mail library
                // attachments, which are no longer listed).
                throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
            }
            if rule.root.kind == .applicationsDirectory {
                // D25: app bundles are removed from the Uninstall page. The
                // junk scan only lists extra copies of the same app.
                let validDuplicateApplicationsRule = rule.risk == .protected
                    && rule.recommendation == .notRecommended
                    && rule.defaultSelection == .unselected
                    && rule.executionEligibility == .eligibleAfterProtectedReview
                    && rule.measurementRequirement == .complete
                    && rule.action == .moveToTrashAfterProtectedReview
                    && rule.allowsManualSelection
                    && rule.cloudPolicy == .metadataOnly
                    && rule.include.entryKinds == [.directory]
                    && rule.include.extensions == ["app"]
                    && rule.include.nameMatcher.mode == .any
                    && rule.include.nameMatcher.values.isEmpty
                    && rule.effectiveRequiresDuplicateBundleIdentifier
                    && rule.effectiveIncludedBundleIdentifiers.isEmpty
                guard validDuplicateApplicationsRule else {
                    throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
                }
            }

            let automatic = rule.action == .moveToTrash
            let reviewed = rule.action == .moveToTrashAfterReview
            let protectedReviewed = rule.action == .moveToTrashAfterProtectedReview
            if automatic, rule.root.kind != .homeRelative {
                throw CleanupRuleValidationError.forbiddenRoot(ruleID: rule.id)
            }
            if automatic,
               forbiddenAutomaticRoots.contains(where: {
                   rule.root.path == $0 || $0.hasPrefix(rule.root.path + "/")
               }) {
                throw CleanupRuleValidationError.forbiddenRoot(ruleID: rule.id)
            }
            if automatic,
               !safeRoots.contains(where: {
                   rule.root.path == $0 || rule.root.path.hasPrefix($0 + "/")
               }),
               !DeveloperToolArtifactCatalog.permitsAutomaticRule(rule),
               !CleanupCoverageCatalog.permitsAutomaticRule(rule) {
                throw CleanupRuleValidationError.forbiddenRoot(ruleID: rule.id)
            }
            if automatic {
                guard !automaticRules.contains(where: {
                    pathsOverlap($0.root.path, rule.root.path)
                        && !haveDisjointNames($0, rule)
                }) else {
                    throw CleanupRuleValidationError.forbiddenRoot(ruleID: rule.id)
                }
                automaticRules.append(rule)
            }

            let validSafeAction = automatic
                && rule.risk == .safe
                && rule.executionEligibility == .eligible
                && rule.measurementRequirement == .complete
                && rule.allowsManualSelection
            let validReviewedAction = reviewed
                && rule.root.kind == .homeRelative
                && rule.risk == .reviewOnly
                && rule.recommendation != .advisoryOnly
                && rule.defaultSelection == .unselected
                && rule.executionEligibility == .eligibleAfterReview
                && rule.measurementRequirement == .complete
                && rule.allowsManualSelection
            let validProtectedReviewedAction = protectedReviewed
                && rule.root.kind == .applicationsDirectory
                && rule.effectiveCandidateScope == .immediateChildren
                && rule.risk == .protected
                && rule.recommendation == .notRecommended
                && rule.defaultSelection == .unselected
                && rule.executionEligibility == .eligibleAfterProtectedReview
                && rule.measurementRequirement == .complete
                && rule.allowsManualSelection
            let validRevealAction = rule.action == .revealOnly
                && rule.risk != .safe
                && rule.recommendation == .advisoryOnly
                && rule.defaultSelection == .forbidden
                && rule.executionEligibility == .advisoryOnly
                && rule.measurementRequirement == .bestEffort
                && !rule.allowsManualSelection
            // D23: emptying the Trash is one root item, red, never preselected,
            // and only ever applies to the user's own `~/.Trash`.
            let validEmptyTrashAction = rule.action == .emptyTrash
                && rule.root.kind == .homeRelative
                && rule.root.path == ".Trash"
                && rule.effectiveCandidateScope == .root
                && rule.risk == .protected
                && rule.recommendation == .notRecommended
                && rule.defaultSelection == .unselected
                && rule.executionEligibility == .eligibleAfterProtectedReview
                && rule.measurementRequirement == .complete
                && rule.allowsManualSelection
                && rule.requiredClosedBundleIDs.isEmpty
            guard validSafeAction || validReviewedAction
                || validProtectedReviewedAction || validRevealAction
                || validEmptyTrashAction else {
                throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
            }
            if rule.defaultSelection == .selected {
                guard rule.risk == .safe,
                      rule.recommendation == .recommended,
                      rule.executionEligibility == .eligible else {
                    throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
                }
            }
            if rule.recommendation == .optional || rule.recommendation == .notRecommended {
                guard rule.defaultSelection != .selected else {
                    throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
                }
            }
            if validSafeAction {
                guard rule.defaultSelection != .forbidden,
                      rule.recommendation != .advisoryOnly else {
                    throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
                }
            }
        }
        try validateContainerExclusions(ruleSet.rules)
    }

    /// A container rule lists one row per child of its root. It must exclude
    /// every child that a more specific rule lists (directly, or because the
    /// specific rule lives inside that child), so no path is listed twice and
    /// no row contains another row.
    private static func validateContainerExclusions(_ rules: [CleanupRule]) throws {
        for container in rules where container.isContainerRule && container.action.isExecutable {
            for other in rules where other.id != container.id && other.root.kind == .homeRelative {
                switch claimedChildren(of: other, under: container) {
                case .none:
                    continue
                case let .names(names):
                    guard names.allSatisfy({ container.exclude.excludes(childName: $0) }) else {
                        throw CleanupRuleValidationError.overlappingRules(ruleID: container.id)
                    }
                case .unbounded:
                    throw CleanupRuleValidationError.overlappingRules(ruleID: container.id)
                }
            }
        }
    }

    private enum ClaimedChildren {
        case none
        case names([String])
        case unbounded
    }

    /// The children of `container.root` that `rule` lists.
    private static func claimedChildren(
        of rule: CleanupRule,
        under container: CleanupRule
    ) -> ClaimedChildren {
        let containerRoot = container.root.path
        let ruleRoot = rule.root.path
        if ruleRoot.hasPrefix(containerRoot + "/") {
            let child = ruleRoot.dropFirst(containerRoot.count + 1)
                .split(separator: "/")
                .first
                .map(String.init) ?? ""
            return .names([child])
        }
        if containerRoot.hasPrefix(ruleRoot + "/") {
            // The other rule would list the container root or one of its
            // ancestors. Only exact names that miss the path are disjoint.
            let next = containerRoot.dropFirst(ruleRoot.count + 1)
                .split(separator: "/")
                .first
                .map(String.init) ?? ""
            guard rule.effectiveCandidateScope == .immediateChildren,
                  rule.include.nameMatcher.mode == .exact,
                  !rule.include.nameMatcher.values.contains(where: {
                      $0.precomposedStringWithCanonicalMapping
                          == next.precomposedStringWithCanonicalMapping
                  }) else {
                return .unbounded
            }
            return .none
        }
        guard ruleRoot == containerRoot else { return .none }
        switch rule.effectiveCandidateScope {
        case .root, .descendantAggregate:
            return .unbounded
        case .immediateChildren:
            switch rule.include.nameMatcher.mode {
            case .exact:
                return .names(rule.include.nameMatcher.values)
            case .prefix:
                return .unbounded
            case .any:
                // Two container rules on one root (Downloads installers and
                // large items) share children; file identity keeps them apart.
                return .none
            }
        }
    }

    private static func validNameValue(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.contains("/")
            && !value.contains("\0")
            && !value.contains("*")
            && !value.contains("?")
            && !value.contains("[")
            && !value.contains("]")
    }

    private static func validNameMatcher(_ matcher: CleanupNameMatcher) -> Bool {
        let values = matcher.values
        let normalizedValues = values.map(\.precomposedStringWithCanonicalMapping)
        guard Set(normalizedValues).count == normalizedValues.count,
              values.allSatisfy(validNameValue) else { return false }
        switch matcher.mode {
        case .any:
            return values.isEmpty
        case .exact, .prefix:
            return !values.isEmpty
        }
    }

    /// Two automatic rules on overlapping roots are allowed only when they can
    /// never list the same path.
    private static func haveDisjointNames(
        _ lhs: CleanupRule,
        _ rhs: CleanupRule
    ) -> Bool {
        if haveDisjointExactNames(lhs, rhs) { return true }
        for (container, other) in [(lhs, rhs), (rhs, lhs)] where container.isContainerRule {
            if case let .names(names) = claimedChildren(of: other, under: container),
               names.allSatisfy({ container.exclude.excludes(childName: $0) }) {
                return true
            }
        }
        return false
    }

    private static func haveDisjointExactNames(
        _ lhs: CleanupRule,
        _ rhs: CleanupRule
    ) -> Bool {
        guard lhs.effectiveCandidateScope == .immediateChildren,
              rhs.effectiveCandidateScope == .immediateChildren,
              lhs.include.nameMatcher.mode == .exact,
              rhs.include.nameMatcher.mode == .exact else { return false }
        let lhsPaths = lhs.include.nameMatcher.values.map {
            "\(lhs.root.path)/\($0.precomposedStringWithCanonicalMapping)"
        }
        let rhsPaths = rhs.include.nameMatcher.values.map {
            "\(rhs.root.path)/\($0.precomposedStringWithCanonicalMapping)"
        }
        return lhsPaths.allSatisfy { lhsPath in
            rhsPaths.allSatisfy { !pathsOverlap(lhsPath, $0) }
        }
    }

    private static func validRoot(_ root: CleanupRuleRoot) -> Bool {
        switch root.kind {
        case .homeRelative:
            validRelativePath(root.path)
        case .applicationsDirectory:
            root.path == "/Applications"
        }
    }

    private static func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("//"),
              !path.contains("\0"),
              !path.contains("~"),
              !path.contains("$"),
              !path.contains("*"),
              !path.contains("?"),
              !path.contains("["),
              !path.contains("]") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    private static func validExtension(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.lowercased()
            && !value.hasPrefix(".")
            && !value.contains("/")
    }

    static func validBundleIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return components.count >= 2
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && components.allSatisfy {
                !$0.isEmpty && String($0).unicodeScalars.allSatisfy(allowed.contains)
            }
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }
}

enum CleanupFileSystemError: Error, Sendable {
    case permissionDenied
    case vanished
    case unreadable
}

protocol ReadOnlyFileSystem: Sendable {
    func snapshot(at url: URL) throws -> FileSnapshot
    func aggregateSnapshot(at url: URL) throws -> FileSnapshot
    func children(of directory: URL) throws -> [URL]
    /// The stored destination of a symbolic link, without following it.
    func symbolicLinkDestination(of url: URL) throws -> String
}

extension ReadOnlyFileSystem {
    func aggregateSnapshot(at url: URL) throws -> FileSnapshot {
        try snapshot(at: url)
    }

    func symbolicLinkDestination(of url: URL) throws -> String {
        do {
            return try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        } catch {
            throw CleanupFileSystemError.unreadable
        }
    }
}

/// D23: a Trash entry that is a symbolic link is only removed when it points
/// back inside the Trash. Removing a link never touches its target, but a link
/// that points elsewhere is left alone so emptying the Trash cannot be read as
/// deleting something outside it.
enum CleanupTrashEntryPolicy {
    static func symbolicLinkStaysInside(
        _ url: URL,
        trashPath: String,
        fileSystem: any ReadOnlyFileSystem
    ) -> Bool {
        guard let destination = try? fileSystem.symbolicLinkDestination(of: url),
              !destination.isEmpty else { return false }
        let target = destination.hasPrefix("/")
            ? destination
            : url.deletingLastPathComponent().appendingPathComponent(destination).path
        let lexicalTarget = PathSafety.lexicalPath(target)
        return PathSafety.isContained(lexicalTarget, in: trashPath, resolvingSymlinks: false)
            && PathSafety.isContained(lexicalTarget, in: trashPath, resolvingSymlinks: true)
    }
}

/// P2-1: copies of an app are duplicates only when bundle identifier,
/// version (`CFBundleShortVersionString`) and build (`CFBundleVersion`) all
/// match. Info.plist is read from disk each scan (no bundle cache), so an app
/// updated in place is compared as it is now.
struct CleanupApplicationRelease: Hashable, Sendable {
    static let activeDeveloperDirectoryCode = "active-developer-directory"
    private static let maximumInfoPlistBytes = 4 * 1_024 * 1_024

    let bundleIdentifier: String
    let shortVersion: String
    let build: String

    var groupKey: String {
        [bundleIdentifier, shortVersion, build].joined(separator: "\u{0}")
    }

    var evidenceCodes: [String] {
        [
            "app-bundle-identifier:\(bundleIdentifier)",
            "app-short-version:\(shortVersion)",
            "app-build:\(build)",
        ]
    }

    static func read(from applicationURL: URL) -> CleanupApplicationRelease? {
        let plistURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plistURL, options: [.mappedIfSafe]),
           data.count <= maximumInfoPlistBytes,
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] {
            return release(from: plist)
        }
        // Other layouts, such as wrapped iOS apps, through Bundle.
        return Bundle(url: applicationURL)?.infoDictionary.flatMap(release(from:))
    }

    private static func release(from plist: [String: Any]) -> CleanupApplicationRelease? {
        guard let identifier = plist["CFBundleIdentifier"] as? String,
              !identifier.isEmpty else { return nil }
        return CleanupApplicationRelease(
            bundleIdentifier: identifier,
            shortVersion: plist["CFBundleShortVersionString"] as? String ?? "",
            build: plist["CFBundleVersion"] as? String ?? ""
        )
    }
}

/// P2-7: the user's own data that some apps keep among their caches. A row
/// holding it is not junk: moving the row would take the data with it.
enum CleanupProtectedContentPolicy {
    /// IDE local edit history, such as JetBrains
    /// `~/Library/Caches/JetBrains/<product>/LocalHistory`.
    private static let localHistoryFolderNames: Set<String> = [
        "localhistory", "local-history", "local_history", "local history",
    ]

    /// Folders where a developer tool cache keeps the user's own data:
    /// Deno stores `Deno.openKv()` databases and localStorage under
    /// `$DENO_DIR/location_data` (by default `~/Library/Caches/deno`), and
    /// Poetry keeps project virtual environments in `pypoetry/virtualenvs`.
    private static let toolDataFolderNames: Set<String> = [
        "location_data", "virtualenvs",
    ]

    /// D83 (repair 1): the agent-state markers below apply only to the AI
    /// tool rules added by D83 and the two Playwright rules. Ordinary package
    /// caches (npx, uv, pip, user caches…) legitimately contain folders named
    /// `config`, `models`, `mcp-server` or `*.pt` files from installed
    /// packages; they keep the integration-baseline protection unchanged.
    /// Membership is code policy like the name lists themselves, so it does
    /// not alter rule content hashes.
    static let persistentAgentStateRuleIDs: Set<String> = [
        "developer.claude-desktop-web-cache", "developer.codex-desktop-web-cache",
        "developer.vscode-web-cache", "developer.vscode-logs",
        "developer.lmstudio-web-cache", "developer.rod-browser-downloads",
        "developer.playwright-mcp-cache", "developer.playwright-browsers",
    ]

    static func protectsPersistentAgentState(ruleID: String) -> Bool {
        persistentAgentStateRuleIDs.contains(ruleID)
    }

    /// D83: recognize persistent state by names only, without opening it.
    /// These markers protect a mixed cache row even if its parent is named
    /// "Caches". Persistent MCP profiles must never be trashed as a whole.
    private static let agentDataNames: Set<String> = [
        "sessions", "archived_sessions", "claude-code-sessions", "local-agent-mode-sessions",
        "checkpoints", "history", "file-history", "shell-snapshots", "shell_snapshots",
        "projects", "project-state", "workspacestorage", "globalstorage", "backups",
        "models", "model", "credentials", "config", "configuration", "settings",
        "local storage", "session storage", "indexeddb", "webstorage",
        "cookies", "login data", "local state", "auth.json", "credentials.json",
        "claude_desktop_config.json", "config.json", "config.toml", "settings.json",
        "history.jsonl", "state.sqlite", "state.db",
    ]
    private static let modelExtensions: Set<String> = ["gguf", "ggml", "safetensors", "onnx", "ckpt", "pth", "pt"]

    static func isProtectedAgentEntry(named name: String) -> Bool {
        let normalized = name.precomposedStringWithCanonicalMapping.lowercased()
        return agentDataNames.contains(normalized)
            || normalized.hasPrefix("mcp-")
            || modelExtensions.contains((normalized as NSString).pathExtension)
    }

    static func isLocalHistoryFolder(named name: String) -> Bool {
        localHistoryFolderNames.contains(name.precomposedStringWithCanonicalMapping.lowercased())
    }

    /// A folder whose contents are the user's data, so the row holding it is
    /// counted, not listed.
    static func isProtectedDataFolder(named name: String) -> Bool {
        let normalized = name.precomposedStringWithCanonicalMapping.lowercased()
        return localHistoryFolderNames.contains(normalized) || toolDataFolderNames.contains(normalized)
    }
}

/// The running and installed apps used for preselection (D22; D47 holds back
/// only rows whose app is running).
struct CleanupApplicationSnapshot: Sendable {
    var runningBundleIdentifiers: Set<String> = []
    var runningBundlePaths: Set<String> = []
    /// The subset of the asked identifiers that belong to an installed app.
    var installedBundleIdentifiers: Set<String> = []

    static let empty = CleanupApplicationSnapshot()
}

protocol CleanupApplicationEnvironment: Sendable {
    func snapshot(checkingInstalled bundleIdentifiers: Set<String>) async -> CleanupApplicationSnapshot
}

/// Nothing running and no app installed: rows whose owner must be inferred
/// stay unresolved. The default for scanners built in tests.
struct NoCleanupApplicationEnvironment: CleanupApplicationEnvironment {
    func snapshot(checkingInstalled _: Set<String>) async -> CleanupApplicationSnapshot {
        .empty
    }
}

struct WorkspaceCleanupApplicationEnvironment: CleanupApplicationEnvironment {
    func snapshot(checkingInstalled bundleIdentifiers: Set<String>) async -> CleanupApplicationSnapshot {
        await MainActor.run {
            let workspace = NSWorkspace.shared
            let running = workspace.runningApplications
            return CleanupApplicationSnapshot(
                runningBundleIdentifiers: Set(running.compactMap(\.bundleIdentifier)),
                runningBundlePaths: Set(running.compactMap {
                    $0.bundleURL.map { PathSafety.lexicalPath($0.path) }
                }),
                installedBundleIdentifiers: Set(bundleIdentifiers.filter {
                    workspace.urlForApplication(withBundleIdentifier: $0) != nil
                })
            )
        }
    }
}

enum CleanupOwnerInferencePolicy {
    /// A row named `com.vendor.app.Helper` may belong to `com.vendor.app`.
    /// Names need at least three reverse-DNS parts so plain file names such as
    /// `install.log` are never read as an app.
    static func bundleIdentifierCandidates(forName name: String) -> [String] {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard components.count >= 3,
              components.allSatisfy({
                  !$0.isEmpty && String($0).unicodeScalars.allSatisfy(allowed.contains)
              }) else { return [] }
        return (3...components.count).reversed().map {
            components.prefix($0).joined(separator: ".")
        }
    }

    /// The longest candidate that is an installed app's bundle identifier.
    static func owner(
        forName name: String,
        installedBundleIdentifiers: Set<String>
    ) -> String? {
        bundleIdentifierCandidates(forName: name).first(where: installedBundleIdentifiers.contains)
    }

    /// Item 10: macOS folders with no owning app, such as crash and
    /// diagnostic reports.
    static func isOwnerless(name: String) -> Bool {
        ["DiagnosticReports"].contains(name)
    }
}

struct FoundationReadOnlyFileSystem: ReadOnlyFileSystem {
    func snapshot(at url: URL) throws -> FileSnapshot {
        let status = try fileStatus(at: url)
        let kind = entryKind(for: status)

        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .volumeIdentifierKey,
            .volumeIsReadOnlyKey
        ]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            throw Self.cleanupError(for: error)
        }
        let logicalSize = kind == .regularFile
            ? Int64(max(0, values.fileSize ?? Int(status.st_size)))
            : 0
        let allocatedSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize
        let modificationNanoseconds = values.contentModificationDate.map(nanoseconds)
        let volumeIdentifier = values.volumeIdentifier
            .map { String(describing: $0) }
            ?? String(status.st_dev)
        let isCloudItem = values.isUbiquitousItem == true
        let isCloudPlaceholder = isCloudItem
            && values.ubiquitousItemDownloadingStatus != .current
        var fileSystemStatus = statfs()
        let fileSystemStatusResult = url.withUnsafeFileSystemRepresentation { path in
            statfs(path, &fileSystemStatus)
        }
        let isReadOnlyVolume = fileSystemStatusResult == 0
            ? (fileSystemStatus.f_flags & UInt32(MNT_RDONLY)) != 0
                || values.volumeIsReadOnly == true
            : values.volumeIsReadOnly ?? true

        return FileSnapshot(
            identity: FileIdentity(
                deviceID: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                entryKind: kind,
                creationTimeNanoseconds: timespecNanoseconds(status.st_birthtimespec)
            ),
            standardizedPath: PathSafety.lexicalPath(url.path),
            volumeIdentifier: volumeIdentifier,
            logicalSizeBytes: logicalSize,
            allocatedSizeBytes: allocatedSize.map { Int64(max(0, $0)) },
            modificationTimeNanoseconds: modificationNanoseconds,
            isWritableVolume: !isReadOnlyVolume,
            isCloudItem: isCloudItem,
            isCloudPlaceholder: isCloudPlaceholder,
            hasSymbolicLinkComponent: PathSafety.containsSymbolicLinkComponent(in: url.path)
        )
    }

    func aggregateSnapshot(at url: URL) throws -> FileSnapshot {
        let status = try fileStatus(at: url)
        let kind = entryKind(for: status)
        let allocated = max(Int64(0), Int64(status.st_blocks)) * 512
        return FileSnapshot(
            identity: FileIdentity(
                deviceID: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                entryKind: kind,
                creationTimeNanoseconds: timespecNanoseconds(status.st_birthtimespec)
            ),
            standardizedPath: PathSafety.lexicalPath(url.path),
            volumeIdentifier: String(status.st_dev),
            logicalSizeBytes: kind == .regularFile ? max(0, Int64(status.st_size)) : 0,
            allocatedSizeBytes: allocated,
            modificationTimeNanoseconds: timespecNanoseconds(status.st_mtimespec),
            isWritableVolume: true,
            isCloudItem: false,
            isCloudPlaceholder: false,
            hasSymbolicLinkComponent: kind == .symbolicLink
        )
    }

    func children(of directory: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw Self.cleanupError(for: error)
        }
    }

    /// Maps an error from listing or reading an item (P2-4). Codes are read in
    /// their own domain, and underlying errors are read too, so a POSIX
    /// EPERM or EACCES (for example the Trash without Full Disk Access) is a
    /// permission problem and the scan can show the Full Disk Access guidance.
    static func cleanupError(for error: Error) -> CleanupFileSystemError {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 4 {
            switch nsError.domain {
            case NSCocoaErrorDomain:
                switch nsError.code {
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                    return .permissionDenied
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                    return .vanished
                default:
                    break
                }
            case NSPOSIXErrorDomain:
                switch Int32(truncatingIfNeeded: nsError.code) {
                case EPERM, EACCES:
                    return .permissionDenied
                case ENOENT:
                    return .vanished
                default:
                    break
                }
            default:
                break
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return .unreadable
    }

    private func nanoseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    private func fileStatus(at url: URL) throws -> stat {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            Darwin.lstat(path, &status)
        }
        guard result == 0 else {
            switch errno {
            case EACCES, EPERM:
                throw CleanupFileSystemError.permissionDenied
            case ENOENT:
                throw CleanupFileSystemError.vanished
            default:
                throw CleanupFileSystemError.unreadable
            }
        }
        return status
    }

    private func entryKind(for status: stat) -> FileEntryKind {
        switch status.st_mode & S_IFMT {
        case S_IFREG:
            .regularFile
        case S_IFDIR:
            .directory
        case S_IFLNK:
            .symbolicLink
        default:
            .other
        }
    }

    private func timespecNanoseconds(_ value: timespec) -> Int64? {
        guard value.tv_sec > 0 else { return nil }
        return Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec)
    }
}

typealias CleanupScanProgressHandler = @Sendable (CleanupScanProgress) async -> Void
typealias CleanupScanOperation = @Sendable (
    CleanupScanRequest,
    @escaping CleanupScanProgressHandler
) async throws -> ScanSession

private struct CleanupScanDeadlineExceeded: Error {}

private struct CleanupAggregateMeasurement {
    var logicalSizeBytes: Int64
    var allocatedSizeBytes: Int64?
    var completeness: MeasurementCompleteness
    var latestModificationTimeNanoseconds: Int64? = nil
    /// P2-7: a protected folder (such as IDE local history) was found inside.
    /// It is not read or counted.
    var containsProtectedData = false

    mutating func add(_ child: CleanupAggregateMeasurement) {
        containsProtectedData = containsProtectedData || child.containsProtectedData
        logicalSizeBytes = CleanupByteCount.adding(
            child.logicalSizeBytes,
            to: logicalSizeBytes
        )
        if let current = allocatedSizeBytes,
           let childAllocated = child.allocatedSizeBytes {
            allocatedSizeBytes = CleanupByteCount.adding(childAllocated, to: current)
        } else {
            allocatedSizeBytes = nil
        }
        if let childLatest = child.latestModificationTimeNanoseconds {
            latestModificationTimeNanoseconds = max(
                latestModificationTimeNanoseconds ?? childLatest,
                childLatest
            )
        }
        merge(child.completeness)
    }

    /// The first reason is kept, except that a skipped symbolic link gives way
    /// to any reason that leaves part of the folder unread. A lower bound whose
    /// reason is `symbolicLinkSkipped` therefore means only links were skipped.
    mutating func markLowerBound(_ reason: CleanupMeasurementIssue) {
        switch completeness {
        case .complete:
            completeness = .lowerBound(reason: reason)
        case .lowerBound(.symbolicLinkSkipped) where reason != .symbolicLinkSkipped:
            completeness = .lowerBound(reason: reason)
        case .lowerBound, .failed:
            break
        }
    }

    private mutating func merge(_ child: MeasurementCompleteness) {
        guard !child.isComplete else { return }
        switch child {
        case .complete:
            break
        case let .lowerBound(reason), let .failed(reason):
            markLowerBound(reason)
        }
    }
}

actor ReadOnlyCleanupScanner {
    private static let maximumCandidatesPerRule = 40
    private let fileSystem: any ReadOnlyFileSystem
    private let ruleSet: CleanupRuleSet
    private let rulesProvenance: CleanupRuleSetProvenance
    private let applicationsURL: URL
    private let applicationEnvironment: any CleanupApplicationEnvironment
    /// `xcode-select`'s link to the active developer directory.
    private let developerDirectoryLinkURL: URL

    init(
        fileSystem: any ReadOnlyFileSystem,
        ruleSet: CleanupRuleSet,
        applicationsURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        applicationEnvironment: any CleanupApplicationEnvironment = NoCleanupApplicationEnvironment(),
        developerDirectoryLinkURL: URL = URL(fileURLWithPath: "/var/db/xcode_select_link")
    ) throws {
        try CleanupRuleValidator.validate(ruleSet)
        self.fileSystem = fileSystem
        self.ruleSet = ruleSet
        self.rulesProvenance = ruleSet.effectiveProvenance
        self.applicationsURL = applicationsURL
        self.applicationEnvironment = applicationEnvironment
        self.developerDirectoryLinkURL = developerDirectoryLinkURL
    }

    /// Bookkeeping shared by every rule in one scan.
    private struct ScanLedger {
        var issues = [ScanIssue]()
        var visitedEntryCount = 0
        var visitedDirectoryPaths = Set<String>()
        var deduplicatedIdentityCount = 0
        var truncatedCandidateCount = 0
        var notActionableCandidateCount = 0
        var excludedPathCandidateCount = 0
        var protectedDataCandidateCount = 0
        var seenIdentityKeys = Set<String>()

        /// D19: found but not listed, with the reason kept in the issues.
        mutating func recordNotActionable(ruleID: String, path: String, kind: ScanIssueKind) {
            issues.append(ScanIssue(ruleID: ruleID, path: path, kind: kind))
            notActionableCandidateCount += 1
            if kind == .candidateContainsExcludedPath {
                excludedPathCandidateCount += 1
            } else if kind == .candidateContainsProtectedData {
                protectedDataCandidateCount += 1
            }
        }
    }

    /// P2-1: the app `xcode-select` points at (its link holds
    /// `<App>.app/Contents/Developer`). Only the link is read; no process runs.
    private func activeDeveloperApplicationPath() -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: developerDirectoryLinkURL.path
        ), !destination.isEmpty else { return nil }
        var url = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : developerDirectoryLinkURL.deletingLastPathComponent().appendingPathComponent(destination)
        while url.path != "/", !url.path.isEmpty {
            if url.pathExtension.lowercased() == "app" {
                return PathSafety.lexicalPath(url.path)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// An item that holds a path the user excluded would always be skipped by
    /// cleanup (`SafeCleanupExecutor` uses the same check), so it is not
    /// actionable. Items inside an excluded path are skipped before this.
    private func holdsExcludedPath(_ path: String, excludedPaths: [String]) -> Bool {
        !excludedPaths.isEmpty
            && ScanExclusionService.intersectsExcludedTree(path, excludedPaths: excludedPaths)
    }

    func scan(
        request: CleanupScanRequest,
        progress: @escaping CleanupScanProgressHandler
    ) async throws -> ScanSession {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(request.maximumDuration)
        let sessionID = ScanSessionID()
        let homePath = PathSafety.lexicalPath(request.userHomeURL.path)
        let excludedPaths = request.excludedURLs.map {
            PathSafety.lexicalPath($0.path)
        }
        var ledger = ScanLedger()
        var permissions = [CleanupPermissionReport]()
        var completedSubcategories = [CleanupScanSubcategory]()
        var skippedRuleIDs = Set<String>()
        var failedRuleIDs = Set<String>()
        var outcome = ScanOutcome.complete

        await progress(progressSnapshot(
            phase: .preparing,
            currentRuleTitle: L10n.text("准备扫描范围", "Preparing scan scope"),
            completedSubcategories: completedSubcategories,
            skippedRuleIDs: skippedRuleIDs,
            failedRuleIDs: failedRuleIDs
        ))

        for rule in ruleSet.rules {
            if Task.isCancelled {
                outcome = .cancelled
                break
            }
            if Date() >= deadline {
                ledger.issues.append(ScanIssue(ruleID: nil, path: nil, kind: .timedOut))
                outcome = .partial
                break
            }

            let ruleTitle = CleanupRuleCopy.title(for: rule)
            let rootURL = rootURL(for: rule, request: request)
            let rootPath = PathSafety.lexicalPath(rootURL.path)
            await progress(progressSnapshot(
                phase: .enumerating,
                currentRuleID: rule.id,
                currentRuleTitle: ruleTitle,
                currentPath: rootPath,
                completedSubcategories: completedSubcategories,
                skippedRuleIDs: skippedRuleIDs,
                failedRuleIDs: failedRuleIDs
            ))
            guard isAllowedRoot(
                rule: rule,
                rootPath: rootPath,
                homePath: homePath
            ) else {
                ledger.issues.append(ScanIssue(
                    ruleID: rule.id,
                    path: rootPath,
                    kind: .outsideAllowedRoot
                ))
                outcome = .partial
                failedRuleIDs.insert(rule.id)
                completedSubcategories.append(subcategory(rule: rule, candidates: []))
                await progress(progressSnapshot(
                    phase: .enumerating,
                    currentRuleTitle: ruleTitle,
                    completedSubcategories: completedSubcategories,
                    skippedRuleIDs: skippedRuleIDs,
                    failedRuleIDs: failedRuleIDs
                ))
                continue
            }

            var ruleCandidates = [ScanCandidate]()
            var reachedDeadline = false
            do {
                let rootSnapshot = try fileSystem.snapshot(at: rootURL)
                ledger.visitedDirectoryPaths.insert(rootSnapshot.standardizedPath)
                guard rootSnapshot.identity.entryKind == .directory,
                      !rootSnapshot.hasSymbolicLinkComponent else {
                    permissions.append(CleanupPermissionReport(
                        ruleID: rule.id,
                        path: rootPath,
                        status: .unreadable
                    ))
                    ledger.issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: rootPath,
                        kind: .symbolicLinkSkipped
                    ))
                    outcome = .partial
                    failedRuleIDs.insert(rule.id)
                    completedSubcategories.append(subcategory(rule: rule, candidates: []))
                    continue
                }
                guard PathSafety.isContained(
                    rootSnapshot.standardizedPath,
                    in: rootPath,
                    resolvingSymlinks: true
                ) else {
                    permissions.append(CleanupPermissionReport(
                        ruleID: rule.id,
                        path: rootPath,
                        status: .unreadable
                    ))
                    ledger.issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: rootPath,
                        kind: .outsideAllowedRoot
                    ))
                    outcome = .partial
                    failedRuleIDs.insert(rule.id)
                    completedSubcategories.append(subcategory(rule: rule, candidates: []))
                    continue
                }
                permissions.append(CleanupPermissionReport(
                    ruleID: rule.id,
                    path: rootPath,
                    status: .readable
                ))

                if rule.root.kind == .applicationsDirectory {
                    ruleCandidates = try duplicateApplicationCandidates(
                        sessionID: sessionID,
                        rule: rule,
                        rootURL: rootURL,
                        rootPath: rootPath,
                        excludedPaths: excludedPaths,
                        deadline: deadline,
                        referenceDate: startedAt,
                        ledger: &ledger
                    )
                } else if rule.action == .emptyTrash {
                    ruleCandidates = try trashCandidates(
                        sessionID: sessionID,
                        rule: rule,
                        rootURL: rootURL,
                        rootSnapshot: rootSnapshot,
                        excludedPaths: excludedPaths,
                        deadline: deadline,
                        referenceDate: startedAt,
                        ledger: &ledger
                    )
                } else {
                    let candidateURLs: [URL]
                    switch rule.effectiveCandidateScope {
                    case .root:
                        candidateURLs = [rootURL]
                    case .immediateChildren:
                        candidateURLs = try fileSystem.children(of: rootURL).sorted(by: {
                            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                        })
                    case .descendantAggregate:
                        // Rejected by the validator; such a result could never be acted on.
                        candidateURLs = []
                    }
                    for (candidateIndex, childURL) in candidateURLs.enumerated() {
                        try checkDeadline(deadline)
                        if candidateIndex.isMultiple(of: 8) {
                            await progress(progressSnapshot(
                                phase: .enumerating,
                                currentRuleID: rule.id,
                                currentRuleTitle: ruleTitle,
                                currentPath: PathSafety.lexicalPath(childURL.path),
                                currentRuleCompletedItemCount: candidateIndex,
                                currentRuleTotalItemCount: candidateURLs.count,
                                completedSubcategories: completedSubcategories,
                                skippedRuleIDs: skippedRuleIDs,
                                failedRuleIDs: failedRuleIDs
                            ))
                        }
                        if isExcluded(childURL.path, by: excludedPaths) {
                            continue
                        }

                        do {
                            var snapshot = try fileSystem.snapshot(at: childURL)
                            ledger.visitedEntryCount += 1
                            if snapshot.identity.entryKind == .directory {
                                ledger.visitedDirectoryPaths.insert(snapshot.standardizedPath)
                            }
                            guard PathSafety.isContained(
                                snapshot.standardizedPath,
                                in: rootPath,
                                resolvingSymlinks: false
                            ) else {
                                ledger.issues.append(ScanIssue(
                                    ruleID: rule.id,
                                    path: snapshot.standardizedPath,
                                    kind: .outsideAllowedRoot
                                ))
                                outcome = .partial
                                continue
                            }
                            guard snapshot.identity.entryKind != .symbolicLink,
                                  !snapshot.hasSymbolicLinkComponent else {
                                ledger.issues.append(ScanIssue(
                                    ruleID: rule.id,
                                    path: snapshot.standardizedPath,
                                    kind: .symbolicLinkSkipped
                                ))
                                continue
                            }
                            guard PathSafety.isContained(
                                snapshot.standardizedPath,
                                in: rootPath,
                                resolvingSymlinks: true
                            ) else {
                                ledger.issues.append(ScanIssue(
                                    ruleID: rule.id,
                                    path: snapshot.standardizedPath,
                                    kind: .outsideAllowedRoot
                                ))
                                outcome = .partial
                                continue
                            }
                            guard !rule.action.isExecutable || snapshot.isWritableVolume else {
                                ledger.issues.append(ScanIssue(
                                    ruleID: rule.id,
                                    path: snapshot.standardizedPath,
                                    kind: .volumeUnavailable
                                ))
                                outcome = .partial
                                continue
                            }
                            if shouldSkipCloudItem(snapshot, policy: rule.cloudPolicy) {
                                ledger.issues.append(ScanIssue(
                                    ruleID: rule.id,
                                    path: snapshot.standardizedPath,
                                    kind: .cloudPlaceholderSkipped
                                ))
                                continue
                            }
                            if !DeveloperCleanupAgePolicy.applies(to: rule),
                               rule.minimumAgeDays > 0,
                               snapshot.modificationTimeNanoseconds == nil {
                                ledger.issues.append(ScanIssue(
                                    ruleID: rule.id,
                                    path: snapshot.standardizedPath,
                                    kind: .metadataUnavailable
                                ))
                                outcome = .partial
                                continue
                            }
                            guard matches(
                                snapshot: snapshot,
                                url: childURL,
                                rule: rule,
                                referenceDate: startedAt
                            ) else {
                                continue
                            }
                            let identityKey = snapshot.identity.deduplicationKey
                            guard !ledger.seenIdentityKeys.contains(identityKey) else {
                                ledger.deduplicatedIdentityCount += 1
                                ledger.issues.append(ScanIssue(
                                    ruleID: rule.id,
                                    path: snapshot.standardizedPath,
                                    kind: .hardLinkDeduplicated
                                ))
                                continue
                            }
                            guard !holdsExcludedPath(
                                snapshot.standardizedPath,
                                excludedPaths: excludedPaths
                            ) else {
                                ledger.recordNotActionable(
                                    ruleID: rule.id,
                                    path: snapshot.standardizedPath,
                                    kind: .candidateContainsExcludedPath
                                )
                                continue
                            }

                            let aggregate = try aggregateSize(
                                snapshot: snapshot,
                                url: childURL,
                                depth: 0,
                                maximumDepth: rule.maximumDepth,
                                ruleID: rule.id,
                                allowedRootPath: rootPath,
                                excludedPaths: excludedPaths,
                                deadline: deadline,
                                ledger: &ledger
                            )
                            // P2-7: moving the row would take the user's own
                            // data with it, so it is counted, not listed.
                            guard !aggregate.containsProtectedData,
                                  !CleanupProtectedContentPolicy.isProtectedDataFolder(
                                      named: childURL.lastPathComponent
                                  ),
                                  !(CleanupProtectedContentPolicy.protectsPersistentAgentState(ruleID: rule.id)
                                    && CleanupProtectedContentPolicy.isProtectedAgentEntry(
                                        named: childURL.lastPathComponent
                                    )) else {
                                ledger.recordNotActionable(
                                    ruleID: rule.id,
                                    path: snapshot.standardizedPath,
                                    kind: .candidateContainsProtectedData
                                )
                                continue
                            }
                            let estimatedSize = aggregate.allocatedSizeBytes
                                ?? aggregate.logicalSizeBytes
                            // A folder that cannot be listed has no known size,
                            // so the threshold cannot drop it: it reaches the
                            // D19 filter below and is counted as not listed.
                            guard aggregate.completeness.isFailed
                                || estimatedSize >= rule.minimumBytes else {
                                continue
                            }
                            snapshot = snapshotWithSizes(
                                snapshot,
                                logical: aggregate.logicalSizeBytes,
                                allocated: aggregate.allocatedSizeBytes
                            )
                            ruleCandidates.append(candidate(
                                sessionID: sessionID,
                                rule: rule,
                                rootURL: rootURL,
                                sourceURL: childURL,
                                snapshot: snapshot,
                                measurementCompleteness: aggregate.completeness,
                                latestContentModificationTimeNanoseconds:
                                    aggregate.latestModificationTimeNanoseconds,
                                developerInactivityThresholdDays:
                                    request.developerInactivityThresholdDays,
                                referenceDate: startedAt
                            ))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch is CleanupScanDeadlineExceeded {
                            throw CleanupScanDeadlineExceeded()
                        } catch {
                            ledger.issues.append(ScanIssue(
                                ruleID: rule.id,
                                path: childURL.path,
                                kind: issueKind(for: error)
                            ))
                            outcome = .partial
                        }
                    }
                }
            } catch is CancellationError {
                outcome = .cancelled
                skippedRuleIDs.insert(rule.id)
            } catch is CleanupScanDeadlineExceeded {
                ledger.issues.append(ScanIssue(ruleID: rule.id, path: rootPath, kind: .timedOut))
                outcome = .partial
                reachedDeadline = true
                failedRuleIDs.insert(rule.id)
            } catch {
                let status = permissionStatus(for: error)
                permissions.removeAll { $0.ruleID == rule.id }
                permissions.append(CleanupPermissionReport(
                    ruleID: rule.id,
                    path: rootPath,
                    status: status
                ))
                if isMissing(error) {
                    skippedRuleIDs.insert(rule.id)
                } else {
                    failedRuleIDs.insert(rule.id)
                    ledger.issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: rootPath,
                        kind: issueKind(for: error)
                    ))
                    outcome = .partial
                }
            }

            // D19: list only what can be selected and removed. Anything else is
            // counted under "some scopes were safely skipped".
            var actionableCandidates = [ScanCandidate]()
            for candidate in ruleCandidates {
                if candidate.isSelectable {
                    actionableCandidates.append(candidate)
                } else {
                    ledger.recordNotActionable(
                        ruleID: rule.id,
                        path: candidate.snapshot.standardizedPath,
                        kind: .candidateNotActionable
                    )
                }
            }
            let retainedCandidates: [ScanCandidate]
            if rule.root.kind == .applicationsDirectory {
                // Whole duplicate groups, already kept within the cap.
                retainedCandidates = actionableCandidates
            } else {
                let sortedCandidates = actionableCandidates.sorted(by: candidateSort)
                retainedCandidates = Array(sortedCandidates.prefix(Self.maximumCandidatesPerRule))
                ledger.truncatedCandidateCount += max(
                    0,
                    sortedCandidates.count - retainedCandidates.count
                )
            }
            completedSubcategories.append(subcategory(
                rule: rule,
                candidates: retainedCandidates
            ))
            await progress(progressSnapshot(
                phase: .enumerating,
                currentRuleTitle: ruleTitle,
                completedSubcategories: completedSubcategories,
                skippedRuleIDs: skippedRuleIDs,
                failedRuleIDs: failedRuleIDs
            ))
            if outcome == .cancelled || reachedDeadline {
                break
            }
        }

        await progress(progressSnapshot(
            phase: .finalizing,
            currentRuleTitle: L10n.text("整理扫描结果", "Finalizing results"),
            completedSubcategories: completedSubcategories,
            skippedRuleIDs: skippedRuleIDs,
            failedRuleIDs: failedRuleIDs
        ))

        let categories = categories(
            from: droppingDuplicateGroupsInUse(
                await resolvingOwners(in: completedSubcategories),
                ledger: &ledger
            )
        )
        let candidates = categories.flatMap(\.candidates)
        let issues = ledger.issues
        if outcome != .cancelled,
           candidates.contains(where: { !$0.measurementCompleteness.isComplete }) {
            outcome = .partial
        }
        if outcome != .cancelled,
           issues.contains(where: { issue in
               switch issue.kind {
               case .permissionDenied, .vanished, .unreadable,
                    .metadataUnavailable, .volumeUnavailable, .outsideAllowedRoot,
                    .timedOut, .candidateNotActionable, .candidateContainsExcludedPath,
                    .candidateContainsProtectedData:
                   return true
               case .symbolicLinkSkipped, .hardLinkDeduplicated,
                    .cloudPlaceholderSkipped:
                   return false
               }
           }) {
            outcome = .partial
        }
        return ScanSession(
            id: sessionID,
            rulesVersion: ruleSet.rulesVersion,
            startedAt: startedAt,
            completedAt: Date(),
            outcome: outcome,
            categories: categories,
            issues: issues,
            permissions: permissions,
            metrics: ScanMetrics(
                visitedEntryCount: ledger.visitedEntryCount,
                visitedDirectoryCount: ledger.visitedDirectoryPaths.count,
                candidateCount: candidates.count,
                deduplicatedIdentityCount: ledger.deduplicatedIdentityCount,
                estimatedCandidateBytes: CleanupByteCount.sum(
                    candidates.map(\.estimatedSizeBytes)
                ),
                completeMeasurementCandidateCount: candidates.filter {
                    $0.measurementCompleteness.isComplete
                }.count,
                lowerBoundMeasurementCandidateCount: candidates.filter {
                    $0.measurementCompleteness.isLowerBound
                }.count,
                failedMeasurementCandidateCount: candidates.filter {
                    $0.measurementCompleteness.isFailed
                }.count,
                permissionFailureCount: issues.filter {
                    $0.kind == .permissionDenied || $0.kind == .unreadable
                }.count,
                cloudSkippedCount: issues.filter {
                    $0.kind == .cloudPlaceholderSkipped
                }.count,
                timedOutRuleCount: Set(issues.compactMap {
                    $0.kind == .timedOut ? $0.ruleID : nil
                }).count,
                truncatedCandidateCount: ledger.truncatedCandidateCount,
                duration: Date().timeIntervalSince(startedAt),
                notActionableCandidateCount: ledger.notActionableCandidateCount,
                excludedPathCandidateCount: ledger.excludedPathCandidateCount,
                protectedDataCandidateCount: ledger.protectedDataCandidateCount
            ),
            system: systemSnapshot(homeURL: request.userHomeURL),
            developerInactivityThresholdDays: request.developerInactivityThresholdDays,
            includedCategoryIDs: request.includedCategoryIDs,
            includedRuleIDs: request.includedRuleIDs,
            rulesProvenance: rulesProvenance
        )
    }

    /// D25/P2-1: lists only extra copies of the same release of an app (the
    /// same bundle identifier, version and build) directly inside
    /// `/Applications`. Info.plist is read first and only copies in a duplicate
    /// group are measured, so large apps without a twin are never traversed.
    /// Whole groups are kept within the per-rule cap, so every listed copy has
    /// a listed sibling that can be kept.
    private func duplicateApplicationCandidates(
        sessionID: ScanSessionID,
        rule: CleanupRule,
        rootURL: URL,
        rootPath: String,
        excludedPaths: [String],
        deadline: Date,
        referenceDate: Date,
        ledger: inout ScanLedger
    ) throws -> [ScanCandidate] {
        var bundles = [(url: URL, snapshot: FileSnapshot, release: CleanupApplicationRelease)]()
        let children = try fileSystem.children(of: rootURL).sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        })
        for childURL in children {
            try checkDeadline(deadline)
            if isExcluded(childURL.path, by: excludedPaths) {
                continue
            }
            do {
                let snapshot = try fileSystem.snapshot(at: childURL)
                ledger.visitedEntryCount += 1
                guard snapshot.identity.entryKind != .symbolicLink,
                      !snapshot.hasSymbolicLinkComponent,
                      PathSafety.isContained(snapshot.standardizedPath, in: rootPath, resolvingSymlinks: false),
                      PathSafety.isContained(snapshot.standardizedPath, in: rootPath, resolvingSymlinks: true) else {
                    if childURL.pathExtension.lowercased() == "app" {
                        ledger.issues.append(ScanIssue(
                            ruleID: rule.id,
                            path: snapshot.standardizedPath,
                            kind: .symbolicLinkSkipped
                        ))
                    }
                    continue
                }
                guard matches(
                    snapshot: snapshot,
                    url: childURL,
                    rule: rule,
                    referenceDate: referenceDate
                ) else { continue }
                guard snapshot.isWritableVolume else {
                    ledger.issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: snapshot.standardizedPath,
                        kind: .volumeUnavailable
                    ))
                    continue
                }
                guard let release = CleanupApplicationRelease.read(from: childURL) else { continue }
                ledger.visitedDirectoryPaths.insert(snapshot.standardizedPath)
                bundles.append((childURL, snapshot, release))
            } catch is CancellationError {
                throw CancellationError()
            } catch is CleanupScanDeadlineExceeded {
                throw CleanupScanDeadlineExceeded()
            } catch {
                ledger.issues.append(ScanIssue(
                    ruleID: rule.id,
                    path: childURL.path,
                    kind: issueKind(for: error)
                ))
            }
        }

        var listedGroups = [(groupID: String, candidates: [ScanCandidate], bytes: Int64)]()
        let groups = Dictionary(grouping: bundles, by: \.release)
            .filter { $0.value.count > 1 }
            .sorted { $0.key.groupKey < $1.key.groupKey }
        let activeDeveloperApplication = activeDeveloperApplicationPath()
        for (release, members) in groups {
            let bundleIdentifier = release.bundleIdentifier
            let groupID = ScanCandidateID(stableKey: release.groupKey).rawValue.uuidString
            var measured = [ScanCandidate]()
            for member in members {
                try checkDeadline(deadline)
                guard !ledger.seenIdentityKeys.contains(member.snapshot.identity.deduplicationKey) else {
                    ledger.deduplicatedIdentityCount += 1
                    ledger.issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: member.snapshot.standardizedPath,
                        kind: .hardLinkDeduplicated
                    ))
                    continue
                }
                guard !holdsExcludedPath(
                    member.snapshot.standardizedPath,
                    excludedPaths: excludedPaths
                ) else {
                    ledger.recordNotActionable(
                        ruleID: rule.id,
                        path: member.snapshot.standardizedPath,
                        kind: .candidateContainsExcludedPath
                    )
                    continue
                }
                let aggregate = try aggregateSize(
                    snapshot: member.snapshot,
                    url: member.url,
                    depth: 0,
                    maximumDepth: rule.maximumDepth,
                    ruleID: rule.id,
                    allowedRootPath: rootPath,
                    excludedPaths: excludedPaths,
                    deadline: deadline,
                    ledger: &ledger
                )
                var copy = candidate(
                    sessionID: sessionID,
                    rule: rule,
                    rootURL: rootURL,
                    sourceURL: member.url,
                    snapshot: snapshotWithSizes(
                        member.snapshot,
                        logical: aggregate.logicalSizeBytes,
                        allocated: aggregate.allocatedSizeBytes
                    ),
                    measurementCompleteness: aggregate.completeness,
                    evidenceCodes: [
                        "duplicate-bundle-identifier",
                        "duplicate-bundle-group:\(groupID)",
                    ] + release.evidenceCodes + (
                        PathSafety.lexicalPath(member.url.path) == activeDeveloperApplication
                            ? [CleanupApplicationRelease.activeDeveloperDirectoryCode]
                            : []
                    ),
                    referenceDate: referenceDate
                )
                copy.ownerResolution = .applicationBundle
                copy.ownerBundleIdentifiers = [bundleIdentifier]
                measured.append(copy)
            }
            let actionable = measured.filter(\.isSelectable)
            // A copy is only listed while another listed copy can be kept.
            let unlisted = actionable.count > 1 ? measured.filter { !$0.isSelectable } : measured
            for copy in unlisted {
                ledger.recordNotActionable(
                    ruleID: rule.id,
                    path: copy.snapshot.standardizedPath,
                    kind: .candidateNotActionable
                )
            }
            guard actionable.count > 1,
                  actionable.contains(where: { $0.estimatedSizeBytes >= rule.minimumBytes }) else {
                continue
            }
            listedGroups.append((
                groupID,
                actionable.sorted(by: candidateSort),
                CleanupByteCount.sum(actionable.map(\.estimatedSizeBytes))
            ))
        }

        var listed = [ScanCandidate]()
        for group in listedGroups.sorted(by: {
            $0.bytes == $1.bytes ? $0.groupID < $1.groupID : $0.bytes > $1.bytes
        }) {
            guard listed.isEmpty
                || listed.count + group.candidates.count <= Self.maximumCandidatesPerRule else {
                ledger.truncatedCandidateCount += group.candidates.count
                continue
            }
            listed.append(contentsOf: group.candidates)
        }
        return listed
    }

    /// D23: one item for the Trash. It carries the top-level entries frozen at
    /// scan time; only those are ever deleted. Entries are measured without
    /// following links, and a link pointing outside the Trash is left out.
    private func trashCandidates(
        sessionID: ScanSessionID,
        rule: CleanupRule,
        rootURL: URL,
        rootSnapshot: FileSnapshot,
        excludedPaths: [String],
        deadline: Date,
        referenceDate: Date,
        ledger: inout ScanLedger
    ) throws -> [ScanCandidate] {
        let trashPath = PathSafety.lexicalPath(rootSnapshot.standardizedPath)
        let children = try fileSystem.children(of: rootURL).sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        })
        var entries = [FileSnapshot]()
        var total = CleanupAggregateMeasurement(
            logicalSizeBytes: 0,
            allocatedSizeBytes: 0,
            completeness: .complete
        )
        for childURL in children {
            try checkDeadline(deadline)
            if isExcluded(childURL.path, by: excludedPaths) {
                total.markLowerBound(.excludedDescendant)
                continue
            }
            // An entry holding a path the user excluded is never frozen, so
            // emptying the Trash leaves it, and the exclusion, in place.
            if holdsExcludedPath(PathSafety.lexicalPath(childURL.path), excludedPaths: excludedPaths) {
                ledger.recordNotActionable(
                    ruleID: rule.id,
                    path: PathSafety.lexicalPath(childURL.path),
                    kind: .candidateContainsExcludedPath
                )
                total.markLowerBound(.excludedDescendant)
                continue
            }
            do {
                let entry = try fileSystem.snapshot(at: childURL)
                ledger.visitedEntryCount += 1
                guard PathSafety.lexicalPath(childURL.deletingLastPathComponent().path) == trashPath,
                      PathSafety.isContained(entry.standardizedPath, in: trashPath, resolvingSymlinks: false) else {
                    ledger.issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: entry.standardizedPath,
                        kind: .outsideAllowedRoot
                    ))
                    total.markLowerBound(.unknown)
                    continue
                }
                // P2-5: a cloud file that is not downloaded is skipped and
                // counted; it is never frozen, so it cannot fail the plan.
                if shouldSkipCloudItem(entry, policy: rule.cloudPolicy) {
                    ledger.issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: entry.standardizedPath,
                        kind: .cloudPlaceholderSkipped
                    ))
                    continue
                }
                let identityKey = entry.identity.deduplicationKey
                guard !ledger.seenIdentityKeys.contains(identityKey) else {
                    ledger.deduplicatedIdentityCount += 1
                    ledger.issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: entry.standardizedPath,
                        kind: .hardLinkDeduplicated
                    ))
                    continue
                }
                if entry.identity.entryKind == .symbolicLink {
                    guard CleanupTrashEntryPolicy.symbolicLinkStaysInside(
                        childURL,
                        trashPath: trashPath,
                        fileSystem: fileSystem
                    ) else {
                        ledger.issues.append(ScanIssue(
                            ruleID: rule.id,
                            path: entry.standardizedPath,
                            kind: .symbolicLinkSkipped
                        ))
                        total.markLowerBound(.symbolicLinkSkipped)
                        continue
                    }
                    ledger.seenIdentityKeys.insert(identityKey)
                    entries.append(entry)
                    total.add(CleanupAggregateMeasurement(
                        logicalSizeBytes: entry.logicalSizeBytes,
                        allocatedSizeBytes: entry.allocatedSizeBytes,
                        completeness: .complete
                    ))
                    continue
                }
                guard !entry.hasSymbolicLinkComponent,
                      PathSafety.isContained(entry.standardizedPath, in: trashPath, resolvingSymlinks: true) else {
                    ledger.issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: entry.standardizedPath,
                        kind: .outsideAllowedRoot
                    ))
                    total.markLowerBound(.unknown)
                    continue
                }
                guard entry.isWritableVolume else {
                    ledger.issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: entry.standardizedPath,
                        kind: .volumeUnavailable
                    ))
                    total.markLowerBound(.unknown)
                    continue
                }
                if entry.identity.entryKind == .directory {
                    ledger.visitedDirectoryPaths.insert(entry.standardizedPath)
                }
                let aggregate = try aggregateSize(
                    snapshot: entry,
                    url: childURL,
                    depth: 0,
                    maximumDepth: rule.maximumDepth,
                    ruleID: rule.id,
                    allowedRootPath: trashPath,
                    excludedPaths: excludedPaths,
                    deadline: deadline,
                    ledger: &ledger
                )
                guard !aggregate.completeness.isFailed else {
                    // An entry that cannot be listed is not frozen for deletion.
                    total.markLowerBound(.unreadableDescendant)
                    continue
                }
                entries.append(snapshotWithSizes(
                    entry,
                    logical: aggregate.logicalSizeBytes,
                    allocated: aggregate.allocatedSizeBytes
                ))
                total.add(aggregate)
            } catch is CancellationError {
                throw CancellationError()
            } catch is CleanupScanDeadlineExceeded {
                throw CleanupScanDeadlineExceeded()
            } catch {
                ledger.issues.append(ScanIssue(
                    ruleID: rule.id,
                    path: childURL.path,
                    kind: issueKind(for: error)
                ))
                total.markLowerBound(measurementIssue(for: error))
            }
        }
        let estimatedSize = total.allocatedSizeBytes ?? total.logicalSizeBytes
        guard !entries.isEmpty, estimatedSize >= rule.minimumBytes else { return [] }
        var trash = candidate(
            sessionID: sessionID,
            rule: rule,
            rootURL: rootURL,
            sourceURL: rootURL,
            snapshot: snapshotWithSizes(
                rootSnapshot,
                logical: total.logicalSizeBytes,
                allocated: total.allocatedSizeBytes
            ),
            measurementCompleteness: total.completeness,
            evidenceCodes: ["frozen-trash-entry-count:\(entries.count)"],
            referenceDate: referenceDate
        )
        trash.permanentDeletionEntries = entries
        return [trash]
    }

    /// D22: resolves row owners from installed apps and records which owners
    /// were running when the scan finished. Preselection skips those rows, and
    /// cleanup checks the owners again before moving anything.
    private func resolvingOwners(
        in subcategories: [CleanupScanSubcategory]
    ) async -> [CleanupScanSubcategory] {
        let inferringRuleIDs = Set(ruleSet.rules.filter {
            $0.ownerInference == .candidateName
        }.map(\.id))
        var askedIdentifiers = Set<String>()
        for candidate in subcategories.flatMap(\.candidates)
            where inferringRuleIDs.contains(candidate.ruleID) {
            askedIdentifiers.formUnion(CleanupOwnerInferencePolicy.bundleIdentifierCandidates(
                forName: candidate.sourceURL.lastPathComponent
            ))
        }
        let applications = await applicationEnvironment.snapshot(
            checkingInstalled: askedIdentifiers
        )
        return subcategories.map { subcategory in
            CleanupScanSubcategory(
                id: subcategory.id,
                title: subcategory.title,
                risk: subcategory.risk,
                recommendation: subcategory.recommendation,
                reason: subcategory.reason,
                candidates: subcategory.candidates.map { candidate in
                    var resolved = candidate
                    if inferringRuleIDs.contains(candidate.ruleID) {
                        if CleanupOwnerInferencePolicy.isOwnerless(
                            name: candidate.sourceURL.lastPathComponent
                        ) {
                            resolved.ownerResolution = .noApplication
                            resolved.ownerBundleIdentifiers = []
                        } else if let owner = CleanupOwnerInferencePolicy.owner(
                            forName: candidate.sourceURL.lastPathComponent,
                            installedBundleIdentifiers: applications.installedBundleIdentifiers
                        ) {
                            resolved.ownerResolution = .inferredFromName
                            resolved.ownerBundleIdentifiers = [owner]
                        } else {
                            resolved.ownerResolution = .unresolved
                            resolved.ownerBundleIdentifiers = []
                        }
                    }
                    return resolved.withRunningOwners(from: applications)
                }
            )
        }
    }

    /// Round 3 (P2-7): a duplicate group whose every copy is running or used
    /// by the command line tools has nothing to remove, so it is not listed
    /// (D19) and its copies are counted as not listed.
    private func droppingDuplicateGroupsInUse(
        _ subcategories: [CleanupScanSubcategory],
        ledger: inout ScanLedger
    ) -> [CleanupScanSubcategory] {
        subcategories.map { subcategory in
            let groups = Dictionary(
                grouping: subcategory.candidates.filter { $0.duplicateApplicationGroupCode != nil },
                by: { $0.duplicateApplicationGroupCode ?? "" }
            )
            let inUse = groups.values.filter { $0.allSatisfy(DuplicateApplicationRetentionPolicy.isProtected) }
            guard !inUse.isEmpty else { return subcategory }
            let dropped = Set(inUse.flatMap { $0.map(\.id) })
            for copy in inUse.flatMap({ $0 }) {
                ledger.recordNotActionable(
                    ruleID: copy.ruleID,
                    path: copy.snapshot.standardizedPath,
                    kind: .candidateNotActionable
                )
            }
            return CleanupScanSubcategory(
                id: subcategory.id,
                title: subcategory.title,
                risk: subcategory.risk,
                recommendation: subcategory.recommendation,
                reason: subcategory.reason,
                candidates: subcategory.candidates.filter { !dropped.contains($0.id) }
            )
        }
    }

    private func rootURL(for rule: CleanupRule, request: CleanupScanRequest) -> URL {
        switch rule.root.kind {
        case .homeRelative:
            request.userHomeURL.appendingPathComponent(rule.root.path, isDirectory: true)
        case .applicationsDirectory:
            applicationsURL
        }
    }

    private func isAllowedRoot(
        rule: CleanupRule,
        rootPath: String,
        homePath: String
    ) -> Bool {
        switch rule.root.kind {
        case .homeRelative:
            PathSafety.isContained(rootPath, in: homePath, resolvingSymlinks: false)
        case .applicationsDirectory:
            rule.root.path == "/Applications"
                && rootPath == PathSafety.lexicalPath(applicationsURL.path)
                && (rule.action == .revealOnly
                    || rule.action == .moveToTrashAfterProtectedReview)
        }
    }

    private func checkDeadline(_ deadline: Date) throws {
        try Task.checkCancellation()
        if Date() >= deadline {
            throw CleanupScanDeadlineExceeded()
        }
    }

    private func candidateSort(_ lhs: ScanCandidate, _ rhs: ScanCandidate) -> Bool {
        if lhs.estimatedSizeBytes == rhs.estimatedSizeBytes {
            return lhs.snapshot.standardizedPath.localizedStandardCompare(
                rhs.snapshot.standardizedPath
            ) == .orderedAscending
        }
        return lhs.estimatedSizeBytes > rhs.estimatedSizeBytes
    }

    private func systemSnapshot(homeURL: URL) -> SystemSnapshot {
        let attributes = (try? FileManager.default.attributesOfFileSystem(forPath: "/")) ?? [:]
        let total = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let volume = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey])
#if arch(arm64)
        let architecture = "arm64"
#elseif arch(x86_64)
        let architecture = "x86_64"
#else
        let architecture = "unknown"
#endif

        return SystemSnapshot(
            osName: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            build: "",
            arch: architecture,
            user: NSUserName(),
            home: PathSafety.lexicalPath(homeURL.path),
            filesystem: "APFS",
            purgeable: "",
            diskName: volume?.volumeName ?? "Macintosh HD",
            diskTotalBytes: total,
            diskUsedBytes: max(0, total - free),
            diskFreeBytes: max(0, free)
        )
    }

    private func aggregateSize(
        snapshot: FileSnapshot,
        url: URL,
        depth: Int,
        maximumDepth: Int,
        ruleID: String,
        allowedRootPath: String,
        excludedPaths: [String],
        deadline: Date,
        ledger: inout ScanLedger
    ) throws -> CleanupAggregateMeasurement {
        try checkDeadline(deadline)
        guard PathSafety.isContained(
            snapshot.standardizedPath,
            in: allowedRootPath,
            resolvingSymlinks: false
        ), PathSafety.isContained(
            snapshot.standardizedPath,
            in: allowedRootPath,
            resolvingSymlinks: true
        ) else {
            ledger.issues.append(ScanIssue(
                ruleID: ruleID,
                path: snapshot.standardizedPath,
                kind: .outsideAllowedRoot
            ))
            return CleanupAggregateMeasurement(
                logicalSizeBytes: 0,
                allocatedSizeBytes: 0,
                completeness: .lowerBound(reason: .unknown),
                latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
            )
        }
        let identityKey = snapshot.identity.deduplicationKey
        guard ledger.seenIdentityKeys.insert(identityKey).inserted else {
            ledger.deduplicatedIdentityCount += 1
            ledger.issues.append(ScanIssue(
                ruleID: ruleID,
                path: snapshot.standardizedPath,
                kind: .hardLinkDeduplicated
            ))
            return CleanupAggregateMeasurement(
                logicalSizeBytes: 0,
                allocatedSizeBytes: 0,
                completeness: .complete,
                latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
            )
        }
        guard snapshot.identity.entryKind == .directory else {
            let logical = snapshot.logicalSizeBytes > 0
                ? snapshot.logicalSizeBytes
                : snapshot.allocatedSizeBytes ?? 0
            return CleanupAggregateMeasurement(
                logicalSizeBytes: logical,
                allocatedSizeBytes: snapshot.allocatedSizeBytes,
                completeness: .complete,
                latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
            )
        }
        guard depth < maximumDepth else {
            return CleanupAggregateMeasurement(
                logicalSizeBytes: max(0, snapshot.logicalSizeBytes),
                allocatedSizeBytes: snapshot.allocatedSizeBytes,
                completeness: .lowerBound(reason: .depthLimitReached),
                latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
            )
        }

        let childURLs: [URL]
        do {
            childURLs = try fileSystem.children(of: url)
        } catch {
            ledger.issues.append(ScanIssue(
                ruleID: ruleID,
                path: snapshot.standardizedPath,
                kind: issueKind(for: error)
            ))
            return CleanupAggregateMeasurement(
                logicalSizeBytes: 0,
                allocatedSizeBytes: nil,
                completeness: .failed(reason: measurementIssue(for: error)),
                latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
            )
        }

        var measurement = CleanupAggregateMeasurement(
            logicalSizeBytes: 0,
            allocatedSizeBytes: 0,
            completeness: .complete,
            latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
        )
        for childURL in childURLs {
            try checkDeadline(deadline)
            if isExcluded(childURL.path, by: excludedPaths) {
                measurement.markLowerBound(.excludedDescendant)
                continue
            }
            do {
                let child = try fileSystem.aggregateSnapshot(at: childURL)
                ledger.visitedEntryCount += 1
                if child.identity.entryKind == .directory {
                    ledger.visitedDirectoryPaths.insert(child.standardizedPath)
                }
                guard child.identity.entryKind != .symbolicLink,
                      !child.hasSymbolicLinkComponent else {
                    ledger.issues.append(ScanIssue(
                        ruleID: ruleID,
                        path: child.standardizedPath,
                        kind: .symbolicLinkSkipped
                    ))
                    measurement.markLowerBound(.symbolicLinkSkipped)
                    continue
                }
                if (child.identity.entryKind == .directory
                        && CleanupProtectedContentPolicy.isProtectedDataFolder(named: childURL.lastPathComponent))
                    || (CleanupProtectedContentPolicy.protectsPersistentAgentState(ruleID: ruleID)
                        && CleanupProtectedContentPolicy.isProtectedAgentEntry(named: childURL.lastPathComponent)) {
                    measurement.containsProtectedData = true
                    continue
                }
                let childSize = try aggregateSize(
                    snapshot: child,
                    url: childURL,
                    depth: depth + 1,
                    maximumDepth: maximumDepth,
                    ruleID: ruleID,
                    allowedRootPath: allowedRootPath,
                    excludedPaths: excludedPaths,
                    deadline: deadline,
                    ledger: &ledger
                )
                measurement.add(childSize)
            } catch is CancellationError {
                throw CancellationError()
            } catch is CleanupScanDeadlineExceeded {
                throw CleanupScanDeadlineExceeded()
            } catch {
                ledger.issues.append(ScanIssue(
                    ruleID: ruleID,
                    path: childURL.path,
                    kind: issueKind(for: error)
                ))
                measurement.markLowerBound(measurementIssue(for: error))
            }
        }
        return measurement
    }

    private func matches(
        snapshot: FileSnapshot,
        url: URL,
        rule: CleanupRule,
        referenceDate: Date
    ) -> Bool {
        guard rule.include.entryKinds.contains(snapshot.identity.entryKind) else {
            return false
        }
        let fileExtension = url.pathExtension.lowercased()
        if !rule.include.extensions.isEmpty,
           !rule.include.extensions.contains(fileExtension) {
            return false
        }
        if !matchesName(url.lastPathComponent, matcher: rule.include.nameMatcher) {
            return false
        }
        if rule.exclude.extensions.contains(fileExtension) {
            return false
        }
        if rule.exclude.excludes(childName: url.lastPathComponent) {
            return false
        }
        guard !DeveloperCleanupAgePolicy.applies(to: rule),
              rule.minimumAgeDays > 0 else {
            return true
        }
        guard let modified = snapshot.modificationTimeNanoseconds else { return false }
        let age = referenceDate.timeIntervalSince1970
            - Double(modified) / 1_000_000_000
        return age >= Double(rule.minimumAgeDays) * 86_400
    }

    private func matchesName(
        _ name: String,
        matcher: CleanupNameMatcher
    ) -> Bool {
        let normalizedName = name.precomposedStringWithCanonicalMapping
        switch matcher.mode {
        case .any:
            return true
        case .exact:
            return matcher.values.contains {
                normalizedName == $0.precomposedStringWithCanonicalMapping
            }
        case .prefix:
            return matcher.values.contains {
                normalizedName.hasPrefix($0.precomposedStringWithCanonicalMapping)
            }
        }
    }

    private func isExcluded(_ path: String, by excludedPaths: [String]) -> Bool {
        excludedPaths.contains {
            PathSafety.isContained(path, in: $0, resolvingSymlinks: false)
        }
    }

    private func shouldSkipCloudItem(
        _ snapshot: FileSnapshot,
        policy: CleanupCloudPolicy
    ) -> Bool {
        switch policy {
        case .metadataOnly:
            false
        case .skipPlaceholder:
            snapshot.isCloudPlaceholder
        case .excludeCloudRoots:
            snapshot.isCloudItem
        }
    }

    private func candidate(
        sessionID: ScanSessionID,
        rule: CleanupRule,
        rootURL: URL,
        sourceURL: URL,
        snapshot: FileSnapshot,
        measurementCompleteness: MeasurementCompleteness = .complete,
        evidenceCodes: [String] = [],
        latestContentModificationTimeNanoseconds: Int64? = nil,
        developerInactivityThresholdDays: Int = DeveloperCleanupAgePolicy.defaultThresholdDays,
        referenceDate: Date = Date()
    ) -> ScanCandidate {
        let developerDecision = DeveloperCleanupAgePolicy.decision(
            for: rule,
            latestModificationTimeNanoseconds: latestContentModificationTimeNanoseconds,
            measurementCompleteness: measurementCompleteness,
            referenceDate: referenceDate,
            thresholdDays: developerInactivityThresholdDays
        )
        let reasonCode = developerDecision?.reasonCode ?? rule.reasonKey
        let reason = developerDecision.map {
            DeveloperCleanupAgePolicy.reason(
                for: $0,
                latestModificationTimeNanoseconds: latestContentModificationTimeNanoseconds,
                referenceDate: referenceDate,
                thresholdDays: developerInactivityThresholdDays
            )
        } ?? CleanupRuleCopy.text(for: rule.reasonKey)
        let developerEvidence = developerDecision.map {
            DeveloperCleanupAgePolicy.evidenceCodes(
                for: $0,
                latestModificationTimeNanoseconds:
                    latestContentModificationTimeNanoseconds,
                thresholdDays: developerInactivityThresholdDays
            )
        } ?? []
        // Item 10: records whether a log was written in the last 7 days. D47
        // preselects the row either way; the row shows the state.
        let logEvidence = CleanupLogPreselectionPolicy.applies(to: rule)
            ? [CleanupLogPreselectionPolicy.evidenceCode(for: CleanupLogPreselectionPolicy.state(
                latestWriteNanoseconds: latestContentModificationTimeNanoseconds,
                measurementCompleteness: measurementCompleteness,
                referenceDate: referenceDate
            ))]
            : []
        var candidate = ScanCandidate(
            id: ScanCandidateID(stableKey: [
                rule.id,
                String(rule.selectionPolicyVersion),
                snapshot.standardizedPath,
                snapshot.volumeIdentifier,
                snapshot.identity.deduplicationKey,
                String(snapshot.identity.creationTimeNanoseconds ?? 0),
            ].joined(separator: "\u{0}")),
            sessionID: sessionID,
            ruleID: rule.id,
            ruleSelectionPolicyVersion: rule.selectionPolicyVersion,
            categoryID: rule.categoryID,
            categoryTitle: CleanupRuleCopy.text(for: rule.categoryTitleKey),
            subcategoryTitle: CleanupRuleCopy.title(for: rule),
            sourceURL: sourceURL,
            allowedRootURL: rule.effectiveCandidateScope == .root
                ? rootURL.deletingLastPathComponent()
                : rootURL,
            snapshot: snapshot,
            risk: developerDecision?.risk ?? rule.risk,
            recommendation: CleanupRecommendation(
                level: developerDecision?.recommendation ?? rule.recommendation,
                reasonCode: reasonCode,
                evidenceCodes: [
                    "storage-analyzer-macos-policy",
                    "bundled-rule",
                    "read-only-metadata",
                ] + developerEvidence + logEvidence + evidenceCodes
            ),
            defaultSelection: developerDecision?.defaultSelection ?? rule.defaultSelection,
            executionEligibility: developerDecision?.executionEligibility
                ?? rule.executionEligibility,
            measurementCompleteness: measurementCompleteness,
            isManuallySelectable: developerDecision?.allowsManualSelection
                ?? rule.allowsManualSelection,
            action: developerDecision?.action ?? rule.action,
            requiredClosedBundleIDs: rule.requiredClosedBundleIDs,
            reason: reason,
            latestContentModificationTimeNanoseconds:
                latestContentModificationTimeNanoseconds,
            developerTool: rule.developerTool,
            developerArtifactKind: rule.developerArtifactKind,
            ruleRevision: rule.maintenance?.revision,
            rulesProvenance: rulesProvenance,
            ruleOwnerDisplayName: rule.ownerDisplayName,
            cleanupImpactText: rule.maintenance?.impact
        )
        if !rule.requiredClosedBundleIDs.isEmpty {
            candidate.ownerResolution = .declared
            candidate.ownerBundleIdentifiers = rule.requiredClosedBundleIDs
        } else if rule.ownerInference != nil {
            // Resolved from installed apps when the scan finishes.
            candidate.ownerResolution = .unresolved
        }
        return candidate
    }

    private func subcategory(
        rule: CleanupRule,
        candidates: [ScanCandidate]
    ) -> CleanupScanSubcategory {
        let representative = candidates.first
        return CleanupScanSubcategory(
            id: rule.id,
            title: CleanupRuleCopy.title(for: rule),
            risk: representative?.risk ?? rule.risk,
            recommendation: representative?.recommendation.level ?? rule.recommendation,
            reason: representative?.reason ?? CleanupRuleCopy.text(for: rule.reasonKey),
            candidates: candidates
        )
    }

    private func categories(
        from subcategories: [CleanupScanSubcategory]
    ) -> [CleanupScanCategory] {
        var categoryOrder = [String]()
        var titles = [String: String]()
        var grouped = [String: [CleanupScanSubcategory]]()
        for subcategory in subcategories {
            guard let rule = ruleSet.rules.first(where: { $0.id == subcategory.id }) else {
                continue
            }
            if grouped[rule.categoryID] == nil {
                categoryOrder.append(rule.categoryID)
            }
            titles[rule.categoryID] = CleanupRuleCopy.text(for: rule.categoryTitleKey)
            grouped[rule.categoryID, default: []].append(subcategory)
        }
        return categoryOrder.map {
            CleanupScanCategory(
                id: $0,
                title: titles[$0] ?? $0,
                subcategories: grouped[$0] ?? []
            )
        }
    }

    private func progressSnapshot(
        phase: CleanupScanPhase,
        currentRuleID: String? = nil,
        currentRuleTitle: String,
        currentPath: String? = nil,
        currentRuleCompletedItemCount: Int = 0,
        currentRuleTotalItemCount: Int = 0,
        completedSubcategories: [CleanupScanSubcategory],
        skippedRuleIDs: Set<String> = [],
        failedRuleIDs: Set<String> = []
    ) -> CleanupScanProgress {
        let completedByID = Dictionary(
            uniqueKeysWithValues: completedSubcategories.map { ($0.id, $0) }
        )
        return CleanupScanProgress(
            phase: phase,
            currentRuleID: currentRuleID,
            currentRuleTitle: currentRuleTitle,
            currentPath: currentPath,
            currentRuleCompletedItemCount: currentRuleCompletedItemCount,
            currentRuleTotalItemCount: currentRuleTotalItemCount,
            completedRuleCount: completedSubcategories.count,
            totalRuleCount: ruleSet.rules.count,
            // Same basis as the three risk cards: items that can be cleaned,
            // without emptying the Trash, which is counted on its own.
            discoveredItemCount: completedSubcategories.reduce(0) {
                $0 + $1.candidates.filter { !$0.action.permanentlyDeletes }.count
            },
            discoveredBytes: CleanupByteCount.sum(
                completedSubcategories.flatMap(\.candidates)
                    .filter { !$0.action.permanentlyDeletes }
                    .map(\.estimatedSizeBytes)
            ),
            groups: ruleSet.rules.map { rule in
                let subcategory = completedByID[rule.id]
                let state: CleanupScanRuleState
                if failedRuleIDs.contains(rule.id) {
                    state = .failed
                } else if skippedRuleIDs.contains(rule.id) {
                    state = .skipped
                } else if rule.id == currentRuleID, phase == .enumerating {
                    state = .scanning
                } else if let subcategory {
                    state = subcategory.candidates.isEmpty ? .clean : .found
                } else if phase == .finalizing {
                    state = .skipped
                } else {
                    state = .pending
                }
                return CleanupScanProgress.GroupSummary(
                    id: rule.id,
                    title: CleanupRuleCopy.title(for: rule),
                    itemCount: subcategory?.candidates.count ?? 0,
                    bytes: subcategory?.discoveredBytes ?? 0,
                    risk: subcategory?.risk ?? rule.risk,
                    state: state,
                    currentPath: rule.id == currentRuleID ? currentPath : nil
                )
            }
        )
    }

    private func snapshotWithSizes(
        _ snapshot: FileSnapshot,
        logical: Int64,
        allocated: Int64?
    ) -> FileSnapshot {
        FileSnapshot(
            identity: snapshot.identity,
            standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier,
            logicalSizeBytes: logical,
            allocatedSizeBytes: allocated,
            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: snapshot.isWritableVolume,
            isCloudItem: snapshot.isCloudItem,
            isCloudPlaceholder: snapshot.isCloudPlaceholder,
            hasSymbolicLinkComponent: snapshot.hasSymbolicLinkComponent
        )
    }

    private func permissionStatus(for error: Error) -> CleanupPermissionStatus {
        guard let fileSystemError = error as? CleanupFileSystemError else {
            return .unreadable
        }
        switch fileSystemError {
        case .permissionDenied:
            return .permissionDenied
        case .vanished:
            return .missing
        case .unreadable:
            return .unreadable
        }
    }

    private func isMissing(_ error: Error) -> Bool {
        guard let fileSystemError = error as? CleanupFileSystemError else {
            return false
        }
        if case .vanished = fileSystemError {
            return true
        }
        return false
    }

    private func issueKind(for error: Error) -> ScanIssueKind {
        if error is CleanupScanDeadlineExceeded {
            return .timedOut
        }
        guard let fileSystemError = error as? CleanupFileSystemError else {
            return .metadataUnavailable
        }
        switch fileSystemError {
        case .permissionDenied:
            return .permissionDenied
        case .vanished:
            return .vanished
        case .unreadable:
            return .unreadable
        }
    }

    private func measurementIssue(for error: Error) -> CleanupMeasurementIssue {
        guard let fileSystemError = error as? CleanupFileSystemError else {
            return .unknown
        }
        switch fileSystemError {
        case .permissionDenied:
            return .permissionDenied
        case .vanished, .unreadable:
            return .unreadableDescendant
        }
    }
}

enum CleanupRuleCopy {
    static func title(for rule: CleanupRule) -> String {
        if let ownerDisplayName = rule.ownerDisplayName {
            return "\(ownerDisplayName) · \(text(for: rule.titleKey))"
        }
        if let tool = rule.developerTool,
           let kind = rule.developerArtifactKind {
            return "\(tool.displayName) · \(kind.displayName)"
        }
        return text(for: rule.titleKey)
    }

    static func text(for key: String) -> String {
        switch key {
        case "cleanup.category.system":
            L10n.text("系统与应用缓存", "System & App Caches")
        case "cleanup.category.browserCaches":
            L10n.text("浏览器缓存", "Browser Caches")
        case "cleanup.category.applicationCaches":
            L10n.text("应用缓存", "Application Caches")
        case "cleanup.category.mail":
            L10n.text("邮件附件", "Mail Attachments")
        case "cleanup.category.trash":
            L10n.text("废纸篓", "Trash")
        case "cleanup.category.developer":
            L10n.text("开发工具与残留", "Developer Tools & Artifacts")
        case "cleanup.category.downloads":
            L10n.text("下载项目", "Downloads")
        case "cleanup.category.applications":
            L10n.text("重复的应用副本", "Duplicate App Copies")
        case "cleanup.category.userData":
            L10n.text("应用数据", "Application Data")
        case "cleanup.category.personalFiles":
            L10n.text("个人文件", "Personal Files")
        case "cleanup.rule.userCaches.title":
            L10n.text("用户缓存", "User Caches")
        case "cleanup.rule.userCaches.reason":
            L10n.text(
                "按应用分行列出用户缓存，可重新生成；默认勾选，所属应用正在运行的行除外，需先退出。未识别所属应用的行无法在清理前确认它是否在运行。只会移入废纸篓，重新打开应用时可能稍慢。",
                "User caches, one row per app. They can be rebuilt. Rows are selected by default unless their app is running; quit it first. For a row whose app is unknown, whether it runs cannot be checked before cleanup. Items only move to Trash, and the app may open a little slower next time."
            )
        case "cleanup.rule.browserCache.title":
            L10n.text("浏览器缓存", "Browser Cache")
        case "cleanup.rule.applicationCache.title":
            L10n.text("应用缓存", "Application Cache")
        case "cleanup.rule.developerCache.title":
            L10n.text("开发缓存", "Developer Cache")
        case "cleanup.reason.knownRegenerableCache":
            L10n.text(
                "该目录位于应用的缓存范围并已精确匹配所属软件，可重新生成；软件未运行时默认勾选，正在运行时需先退出。首次重新打开或加载内容可能更慢。",
                "This exact cache path belongs to its app and can be rebuilt. It is selected by default while the app is not running; quit the app first if it is. The first launch or content load may be slower."
            )
        case "cleanup.rule.mailDownloads.title":
            L10n.text("邮件附件副本", "Mail Attachment Copies")
        case "cleanup.reason.mailDownloads":
            L10n.text(
                "打开邮件附件时系统另存的副本，邮件里的原附件仍保留；是否还需要这些副本由你判断，默认不选。清理前请退出“邮件”。",
                "Copies the system saved when you opened mail attachments; the attachments stay in your mail. Decide whether you still need these copies; they are not selected by default. Quit Mail before cleanup."
            )
        case "cleanup.rule.systemManagedCache.title":
            L10n.text("系统管理缓存", "System-Managed Cache")
        case "cleanup.reason.systemManagedCache":
            L10n.text(
                "由 macOS 的 iCloud 服务管理的缓存，可以移入废纸篓，系统会按需重新下载；可能暂时影响 iCloud 应用的离线内容，因此需要你判断，默认不选。",
                "A cache managed by macOS iCloud services. It can move to Trash and is downloaded again as needed, but iCloud apps may lose offline content for a while, so it needs your judgment and is not selected by default."
            )
        case "cleanup.rule.diagnosticLogs.title":
            L10n.text("诊断日志", "Diagnostic Logs")
        case "cleanup.reason.diagnosticLogs":
            L10n.text(
                "系统诊断记录，删除不影响系统运行，默认勾选；最近 7 天内仍有写入时会在行内注明。如需排查问题，请先取消勾选。",
                "System diagnostic records. Removing them does not affect macOS. They are selected by default; a row still written in the last 7 days says so. Clear the check if you still need them for troubleshooting."
            )
        case "cleanup.rule.applicationLogs.title":
            L10n.text("应用日志", "Application Logs")
        case "cleanup.reason.applicationLogs":
            L10n.text(
                "应用日志，删除不影响应用使用；应用未运行时默认勾选，最近 7 天内仍有写入时会在行内注明。",
                "App logs. Removing them does not affect the app. They are selected by default while the app is not running; a row still written in the last 7 days says so."
            )
        case "cleanup.rule.userTrash.title":
            L10n.text("清空废纸篓", "Empty Trash")
        case "cleanup.reason.userTrash":
            L10n.text(
                "永久删除扫描时废纸篓里的项目，不可恢复；默认不选，执行前需要单独二次确认。扫描后放入废纸篓的项目（包括本次清理移入的）不会被删除。",
                "Permanently deletes the items that were in the Trash during the scan. This cannot be undone; it is not selected by default and needs its own two confirmations. Items put in the Trash after the scan, including this cleanup's items, are not deleted."
            )
        case "cleanup.rule.userLogs.title":
            L10n.text("用户日志", "User Logs")
        case "cleanup.rule.userLogs.reason":
            L10n.text(
                "按来源分行列出用户日志，删除不影响应用使用；默认勾选，所属应用正在运行的行除外，最近 7 天内仍有写入的行会在行内注明。如需排查问题，请先取消勾选相关日志。",
                "User logs, one row per source. Removing them does not affect apps. Rows are selected by default unless their app is running; rows still written in the last 7 days say so. Clear the check for logs you still need for troubleshooting."
            )
        case "cleanup.rule.xcodeDerivedData.title":
            L10n.text("Xcode Derived Data", "Xcode Derived Data")
        case "cleanup.rule.xcodeDerivedData.reason":
            L10n.text(
                "Xcode 可重新生成构建派生数据；删除后首次构建会更慢。",
                "Xcode can rebuild derived data; the next build may take longer."
            )
        case "cleanup.rule.xcodeDeviceSupport.title":
            L10n.text("Xcode 设备支持文件", "Xcode Device Support")
        case "cleanup.rule.xcodeDeviceSupport.reason":
            L10n.text(
                "Xcode 可按需重新下载设备支持文件；清理前请退出 Xcode。",
                "Xcode can download device support again; quit Xcode before cleanup."
            )
        case "cleanup.rule.dotCache.title":
            L10n.text("通用开发缓存", "General Developer Cache")
        case "cleanup.rule.npmCache.title":
            L10n.text("npm 缓存", "npm Cache")
        case "cleanup.rule.npxCache.title":
            L10n.text("npm 临时执行缓存（_npx）", "npm Temporary Execution Cache (_npx)")
        case "cleanup.rule.npmContentCache.title":
            L10n.text("npm 内容缓存（_cacache）", "npm Content Cache (_cacache)")
        case "cleanup.rule.homebrewCache.title":
            L10n.text("Homebrew 下载缓存", "Homebrew Download Cache")
        case "cleanup.rule.uvCache.title":
            L10n.text("uv 包缓存", "uv Package Cache")
        case "cleanup.rule.pnpmStore.title":
            L10n.text("pnpm 内容缓存", "pnpm Content Cache")
        case "cleanup.rule.gradleCache.title":
            L10n.text("Gradle 缓存", "Gradle Cache")
        case "cleanup.rule.mavenCache.title":
            L10n.text("Maven 本地仓库", "Maven Local Repository")
        case "cleanup.rule.cargoRegistry.title":
            L10n.text("Cargo Registry 缓存", "Cargo Registry Cache")
        case "cleanup.rule.cargoGit.title":
            L10n.text("Cargo Git 缓存", "Cargo Git Cache")
        case "cleanup.rule.libraryPnpmStore.title":
            L10n.text("pnpm 用户仓库", "pnpm User Store")
        case "cleanup.rule.goModuleCache.title":
            L10n.text("Go 模块缓存", "Go Module Cache")
        case "cleanup.reason.regenerableDeveloperCache":
            L10n.text(
                "开发工具可重新下载或生成这些缓存；清理后下一次构建可能更慢。",
                "Developer tools can download or rebuild this cache; the next build may be slower."
            )
        case "cleanup.reason.developerToolLogs":
            L10n.text(
                "开发工具运行时写入的日志，删除不影响工具使用；所属应用未运行时默认勾选，最近 7 天内仍有写入时会在行内注明。如需排查问题，请先取消勾选。",
                "Logs written by the developer tool. Removing them does not affect the tool. They are selected by default while its app is not running; a row still written in the last 7 days says so. Clear the check if you still need them for troubleshooting."
            )
        case "cleanup.reason.developerInactiveYear":
            L10n.text("超过一年未修改的开发缓存，可重新生成", "Developer cache unchanged for over a year; it can be rebuilt")
        case "cleanup.reason.developerInactiveReview":
            L10n.text("较长时间未修改的开发缓存，请核对用途后再清理", "Developer cache unchanged for a while; check its use before cleanup")
        case "cleanup.reason.developerRecent":
            L10n.text("近期仍有修改的开发产物，可能仍在使用", "Developer files changed recently and may still be in use")
        case "cleanup.reason.developerActivityUnverified":
            L10n.text("部分内容无法读取，不能确认是否仍在使用", "Part of the folder could not be read, so recent use cannot be ruled out")
        case "cleanup.reason.developerActivityUnknown":
            L10n.text("无法确认最近修改时间", "The latest change time could not be verified")
        case "cleanup.rule.developerToolArtifact.title":
            L10n.text("开发工具残留", "Developer Tool Artifact")
        case "cleanup.rule.coreSimulator.title":
            L10n.text("CoreSimulator 数据", "CoreSimulator Data")
        case "cleanup.rule.coreSimulator.reason":
            L10n.text(
                "模拟器目录可能包含应用测试状态；请先退出 Xcode 与模拟器，并确认这些状态不再需要。",
                "Simulator data may include app test state; quit Xcode and Simulator, then confirm that state is no longer needed."
            )
        case "cleanup.rule.dockerData.title":
            L10n.text("Docker 数据", "Docker Data")
        case "cleanup.rule.dockerData.reason":
            L10n.text(
                "其中可能包含镜像、卷和开发环境状态，应优先使用 Docker 自带管理工具。",
                "This may contain images, volumes, and environment state; use Docker's own management tools."
            )
        case "cleanup.rule.downloadInstallers.title":
            L10n.text("下载的安装包", "Downloaded Installers")
        case "cleanup.rule.downloadInstallers.reason":
            L10n.text(
                "安装包可能是唯一的离线副本；确认应用已安装且不再需要重新安装后再手动选择。",
                "An installer may be the only offline copy; select it manually only after confirming the app is installed and no reinstall copy is needed."
            )
        case "cleanup.rule.downloadLargeItems.title":
            L10n.text("下载目录大项目", "Large Download Items")
        case "cleanup.rule.downloadLargeItems.reason":
            L10n.text(
                "下载内容可能是个人文件或仍在使用的资料；核对后可手动选择。",
                "Downloads may be personal or still needed; select them manually only after review."
            )
        case "cleanup.rule.duplicateInstalledApps.title":
            L10n.text("重复安装的应用副本", "Duplicate App Copies")
        case "cleanup.rule.duplicateInstalledApps.reason":
            L10n.text(
                "发现同一应用的多个副本（应用标识、版本和构建号都相同）；核对用途后，可在双重确认下把多余副本移入废纸篓。正在运行的副本和命令行工具当前使用的 Xcode 总会保留、不能勾选；其余副本整组勾选时自动保留一份（优先直接位于“应用程序”文件夹的、最近更新的）。删除应用本身请使用“卸载”页。",
                "Several copies of the same app were found (same identifier, version and build). After checking their purpose, you can move extra copies to Trash with two confirmations. A copy that is running, and the Xcode the command line tools use, are always kept and cannot be checked; checking all other copies keeps one of them (preferring one directly in Applications, then the most recently updated). To remove an app itself, use Uninstall."
            )
        case "cleanup.rule.applicationSupport.title":
            L10n.text("Application Support", "Application Support")
        case "cleanup.rule.containers.title":
            L10n.text("应用容器", "App Containers")
        case "cleanup.rule.groupContainers.title":
            L10n.text("共享应用容器", "Shared App Containers")
        case "cleanup.reason.manualAppData":
            L10n.text(
                "可能包含登录状态、数据库、下载内容或应用设置；请先确认所属应用和备份。",
                "This may contain sign-in state, databases, downloads, or settings; confirm ownership and backups first."
            )
        case "cleanup.rule.desktopLargeItems.title":
            L10n.text("桌面大项目", "Large Desktop Items")
        case "cleanup.rule.documentsLargeItems.title":
            L10n.text("文稿大项目", "Large Document Items")
        case "cleanup.rule.moviesLargeItems.title":
            L10n.text("影片大项目", "Large Movie Items")
        case "cleanup.rule.musicLargeItems.title":
            L10n.text("音乐大项目", "Large Music Items")
        case "cleanup.rule.picturesLargeItems.title":
            L10n.text("图片大项目", "Large Picture Items")
        case "cleanup.reason.personalData":
            L10n.text(
                "这是个人内容；确认已备份且不再需要后才可手动选择。",
                "This is personal content; select it manually only after confirming a backup and that it is no longer needed."
            )
        default:
            key
        }
    }
}

enum CleanupScanOperations {
    static let live: CleanupScanOperation = { request, progress in
        let loadedRuleSet = try CleanupRuleSetLoader.loadBundled()
        let ruleSet = scopedRuleSet(
            loadedRuleSet,
            includedCategoryIDs: request.includedCategoryIDs,
            includedRuleIDs: request.includedRuleIDs
        )
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: FoundationReadOnlyFileSystem(),
            ruleSet: ruleSet,
            applicationEnvironment: WorkspaceCleanupApplicationEnvironment()
        )
        return try await scanner.scan(request: request, progress: progress)
    }

    static func scopedRuleSet(
        _ ruleSet: CleanupRuleSet,
        includedCategoryIDs: Set<String>?,
        includedRuleIDs: Set<String>? = nil
    ) -> CleanupRuleSet {
        guard includedCategoryIDs != nil || includedRuleIDs != nil else { return ruleSet }
        return CleanupRuleSet(
            schemaVersion: ruleSet.schemaVersion,
            rulesVersion: ruleSet.rulesVersion,
            rules: ruleSet.rules.filter { rule in
                (includedCategoryIDs?.contains(rule.categoryID) ?? true)
                    && (includedRuleIDs?.contains(rule.id) ?? true)
            },
            fullSetProvenance: ruleSet.effectiveProvenance
        )
    }
}
