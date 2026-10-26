import Foundation

/// D183: shared by plan validation and the checks immediately before a move.
enum CleanupNamedDescendantScope {
    /// Keep the global Mail protection intact for every other flow/rule.
    static func permitsProtectedMailLibrary(_ rule: CleanupRule) -> Bool {
        rule.id == "mail.library-attachment-folders"
            && rule.root.kind == .homeRelative && rule.root.path == "Library/Mail"
            && rule.effectiveCandidateScope == .namedDescendantDirectories
            && rule.include.entryKinds == [.directory]
            && rule.include.nameMatcher.mode == .exact
            && rule.include.nameMatcher.values == ["Attachments"]
            && rule.risk == .reviewOnly && rule.defaultSelection == .unselected
            && rule.action == .moveToTrashAfterReview
            && rule.requiredClosedBundleIDs == ["com.apple.mail"]
    }

    static func matches(sourcePath: String, rootPath: String, rule: CleanupRule) -> Bool {
        guard rule.root.kind == .homeRelative,
              rule.effectiveCandidateScope == .namedDescendantDirectories,
              rule.include.nameMatcher.mode == .exact,
              sourcePath != rootPath,
              PathSafety.isContained(sourcePath, in: rootPath, resolvingSymlinks: false) else { return false }
        let rootComponents = URL(fileURLWithPath: rootPath).pathComponents
        let ruleComponents = rule.root.path.split(separator: "/").map(String.init)
        let components = URL(fileURLWithPath: sourcePath).pathComponents
        let depth = components.count - rootComponents.count
        return rootComponents.count >= ruleComponents.count
            && Array(rootComponents.suffix(ruleComponents.count)) == ruleComponents
            && depth > 0 && depth <= rule.maximumDepth
            && rule.include.nameMatcher.values.contains {
                components.last?.precomposedStringWithCanonicalMapping == $0.precomposedStringWithCanonicalMapping
            }
    }
}
