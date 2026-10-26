import CryptoKit
import Foundation

enum CleanupRuleSource: String, Codable, Sendable {
    case json
    case developerCatalog = "developer-catalog"
    case coverageCatalog = "coverage-catalog"
}

/// Maintenance annotations do not filter matches or grant execution rights.
/// Conditions name fields in the maintenance schema, not arbitrary key paths.
struct CleanupRuleApplicability: Codable, Equatable, Sendable {
    let field: String
    let value: String
}

struct CleanupRuleMaintenance: Codable, Equatable, Sendable {
    let source: CleanupRuleSource
    var revision: Int
    var checkedAt: String
    var applicability: [CleanupRuleApplicability] = []
    var impact: String
    var evidenceURLs: [String] = []
}

struct CleanupRuleReference: Codable, Equatable, Sendable {
    let ruleID: String
    /// Missing for synthetic rules and old receipts; never guess a revision.
    let revision: Int?
    let contentHash: String
}

struct CleanupRuleSetProvenance: Codable, Equatable, Sendable {
    let fingerprint: String
    let rules: [CleanupRuleReference]
}

/// JSON object keys, unordered collections inside a rule and Unicode are
/// normalized before hashing. All encoded rule fields participate, including
/// maintenance data. The top-level rule order is kept: the scanner lets the
/// first rule claim a shared identity, so reordering rules changes behavior.
enum CleanupRuleFingerprint {
    static func normalizedData(for rule: CleanupRule, includingMaintenance: Bool = true) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as! [String: Any]
        object["candidateScope"] = rule.effectiveCandidateScope.rawValue
        // Keep nil absent so D183 does not change any existing rule's hash.
        if let limit = rule.maximumCandidates { object["maximumCandidates"] = limit }
        object["includedBundleIdentifiers"] = Array(rule.effectiveIncludedBundleIdentifiers)
        object["requiresDuplicateBundleIdentifier"] = rule.effectiveRequiresDuplicateBundleIdentifier
        var exclusion = object["exclude"] as! [String: Any]
        exclusion["namePrefixes"] = rule.exclude.namePrefixes ?? []
        object["exclude"] = exclusion
        if !includingMaintenance { object.removeValue(forKey: "maintenance") }
        return try data(normalize(object))
    }

    static func contentHash(for rule: CleanupRule) throws -> String {
        var object = try JSONSerialization.jsonObject(with: normalizedData(for: rule)) as! [String: Any]
        if var maintenance = object["maintenance"] as? [String: Any] {
            maintenance.removeValue(forKey: "revision")
            object["maintenance"] = maintenance
        }
        return hash(try data(object))
    }

    static func provenance(for ruleSet: CleanupRuleSet) -> CleanupRuleSetProvenance {
        do {
            let rules = try ruleSet.rules.map { rule in
                try JSONSerialization.jsonObject(with: normalizedData(for: rule))
            }
            // Each rule is already normalized internally; the array itself
            // must not be sorted (schema 2).
            let fingerprint = hash(try data([
                "fingerprintSchema": 2,
                "ruleSchema": ruleSet.schemaVersion,
                "rules": rules,
            ] as [String: Any]))
            return CleanupRuleSetProvenance(fingerprint: fingerprint, rules: try ruleSet.rules
                .map { rule in
                    CleanupRuleReference(ruleID: rule.id, revision: rule.maintenance?.revision,
                        contentHash: try CleanupRuleFingerprint.contentHash(for: rule))
                }
                .sorted { $0.ruleID < $1.ruleID })
        } catch {
            // CleanupRule contains only finite integers, strings, enums and
            // collections. An encoding failure is a programmer error.
            preconditionFailure("Cleanup rule canonical encoding failed: \(error)")
        }
    }

    private static func normalize(_ value: Any) throws -> Any {
        if let object = value as? [String: Any] {
            return try object.mapValues(normalize)
        }
        if let array = value as? [Any] {
            return try array.map { element in
                let normalized = try normalize(element)
                return (normalized, try data(normalized))
            }.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
        }
        if let string = value as? String { return string.precomposedStringWithCanonicalMapping }
        return value
    }

    private static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CleanupRuleBaseline: Codable, Sendable {
    let schemaVersion: Int
    let entries: [Entry]
    /// Immutable matching/selection snapshot captured from integration 52f722ac.
    let legacyRules: [CleanupRule]

    struct Entry: Codable, Sendable {
        let ruleID: String
        let revision: Int
        let contentHash: String
    }
}

enum CleanupRuleMaintenanceError: Error, Equatable {
    case missingMetadata(String)
    case invalidMetadata(String)
    case sourceMismatch(String)
    case unknownApplicabilityField(String, String)
    case revisionNotIncremented(String)
    case revisionRegressed(String)
    case invalidBaseline
}

enum CleanupRuleMaintenanceValidator {
    static func validate(_ ruleSet: CleanupRuleSet, baseline: CleanupRuleBaseline? = nil) throws {
        guard Set(ruleSet.rules.map(\.id)).count == ruleSet.rules.count else {
            throw CleanupRuleValidationError.duplicateRuleID(ruleSet.rules.first { rule in
                ruleSet.rules.filter { $0.id == rule.id }.count > 1
            }?.id ?? "")
        }
        for rule in ruleSet.rules {
            guard let metadata = rule.maintenance else {
                throw CleanupRuleMaintenanceError.missingMetadata(rule.id)
            }
            guard metadata.revision > 0, validDate(metadata.checkedAt),
                  !metadata.impact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  metadata.impact.count <= 200,
                  metadata.evidenceURLs.allSatisfy({ URL(string: $0)?.scheme == "https" }),
                  Set(metadata.applicability.map(\.field)).count == metadata.applicability.count else {
                throw CleanupRuleMaintenanceError.invalidMetadata(rule.id)
            }
            for condition in metadata.applicability {
                switch condition.field {
                case "applicationBundleIdentifier":
                    guard CleanupRuleValidator.validBundleIdentifier(condition.value) else {
                        throw CleanupRuleMaintenanceError.invalidMetadata(rule.id)
                    }
                case "minimumApplicationVersion":
                    guard metadata.applicability.contains(where: { $0.field == "applicationBundleIdentifier" }),
                          condition.value.split(separator: ".", omittingEmptySubsequences: false)
                            .allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
                        throw CleanupRuleMaintenanceError.invalidMetadata(rule.id)
                    }
                default:
                    throw CleanupRuleMaintenanceError.unknownApplicabilityField(rule.id, condition.field)
                }
            }
        }
        guard let baseline else { return }
        guard baseline.schemaVersion == 1,
              Set(baseline.entries.map(\.ruleID)).count == baseline.entries.count,
              baseline.entries.allSatisfy({ $0.revision > 0 && $0.contentHash.count == 64 }) else {
            throw CleanupRuleMaintenanceError.invalidBaseline
        }
        let entries = Dictionary(uniqueKeysWithValues: baseline.entries.map { ($0.ruleID, $0) })
        for rule in ruleSet.rules {
            guard let old = entries[rule.id], let metadata = rule.maintenance else { continue }
            guard metadata.revision >= old.revision else {
                throw CleanupRuleMaintenanceError.revisionRegressed(rule.id)
            }
            if try contentChanged(rule, from: old), metadata.revision <= old.revision {
                throw CleanupRuleMaintenanceError.revisionNotIncremented(rule.id)
            }
        }
    }

    private static func contentChanged(_ rule: CleanupRule, from entry: CleanupRuleBaseline.Entry) throws -> Bool {
        try CleanupRuleFingerprint.contentHash(for: rule) != entry.contentHash
    }

    private static func validDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }
}
