import Foundation
import XCTest
@testable import StorageCleanerMac

/// Shared by rule and execution tests in both Debug and Release.
enum CleanupRuleTestFixtures {
    static func resourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/\(name)")
    }

    static func baseline() throws -> CleanupRuleBaseline {
        try JSONDecoder().decode(CleanupRuleBaseline.self,
            from: Data(contentsOf: resourceURL("CleanupRules.baseline.json")))
    }

    static func replacing(_ rule: CleanupRule, fields: [String: Any]) throws -> CleanupRule {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        for (key, value) in fields { object[key] = value }
        return try JSONDecoder().decode(CleanupRule.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func set(_ rules: [CleanupRule], version: String = "provenance.fixture") -> CleanupRuleSet {
        CleanupRuleSet(schemaVersion: 2, rulesVersion: version, rules: rules)
    }

    static func write(_ url: URL, bytes: Int = 131_072) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
    }

    static func ageTree(_ root: URL, days: Double = 400) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.path)
    }

    static func scan(_ rules: CleanupRuleSet, home: URL,
                     applications: CleanupApplicationSnapshot = .empty) async throws -> ScanSession {
        let scanner = try ReadOnlyCleanupScanner(fileSystem: RuleTestReadOnlyFileSystem(root: home), ruleSet: rules,
            applicationsURL: home.appendingPathComponent("Applications"),
            applicationEnvironment: RuleTestApplicationEnvironment(value: applications))
        return try await scanner.scan(request: CleanupScanRequest(userHomeURL: home)) { _ in }
    }

    static func seed(_ rule: CleanupRule, home: URL) throws {
        guard rule.root.kind == .homeRelative else { return }
        let root = home.appendingPathComponent(rule.root.path)
        let bytes = Int(max(rule.minimumBytes, 4_096)) + 8_192
        if rule.effectiveCandidateScope == .root {
            try write(root.appendingPathComponent("generated.bin"), bytes: bytes)
        } else if rule.include.nameMatcher.mode == .exact {
            for name in rule.include.nameMatcher.values {
                try write(root.appendingPathComponent(name).appendingPathComponent("generated.bin"), bytes: bytes)
            }
        } else {
            let name = "fixture-\(rule.id)"
            if rule.include.entryKinds.contains(.directory) && rule.include.extensions.isEmpty {
                try write(root.appendingPathComponent(name).appendingPathComponent("generated.bin"), bytes: bytes)
            } else {
                let ext = rule.include.extensions.sorted().first ?? "bin"
                try write(root.appendingPathComponent("\(name).\(ext)"), bytes: bytes)
            }
        }
    }
}

private struct RuleTestApplicationEnvironment: CleanupApplicationEnvironment {
    let value: CleanupApplicationSnapshot
    func snapshot(checkingInstalled _: Set<String>) async -> CleanupApplicationSnapshot { value }
}

struct RuleTestNoRunningApplicationChecker: CleanupRunningApplicationChecking {
    func isRunning(bundleIdentifier _: String) async -> Bool { false }
}

/// Ignore inaccessible system ancestors of an owned temporary fixture while
/// retaining every link check inside that fixture. Product PathSafety stays
/// unchanged; this is the same fixture injection used by the scanner tests.
struct RuleTestReadOnlyFileSystem: ReadOnlyFileSystem {
    let root: URL

    func snapshot(at url: URL) throws -> FileSnapshot {
        let value = try FoundationReadOnlyFileSystem().snapshot(at: url)
        let rootPath = PathSafety.lexicalPath(root.path)
        let path = PathSafety.lexicalPath(url.path)
        guard PathSafety.isContained(path, in: rootPath, resolvingSymlinks: false) else {
            throw CleanupFileSystemError.unreadable
        }
        var current = URL(fileURLWithPath: rootPath, isDirectory: true)
        var linked = false
        let relative = path.dropFirst(rootPath.count).split(separator: "/")
        for part in relative {
            current.appendPathComponent(String(part))
            let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { linked = true; break }
        }
        return FileSnapshot(identity: value.identity, standardizedPath: value.standardizedPath,
            volumeIdentifier: value.volumeIdentifier, logicalSizeBytes: value.logicalSizeBytes,
            allocatedSizeBytes: value.allocatedSizeBytes, modificationTimeNanoseconds: value.modificationTimeNanoseconds,
            isWritableVolume: value.isWritableVolume, isCloudItem: value.isCloudItem,
            isCloudPlaceholder: value.isCloudPlaceholder, hasSymbolicLinkComponent: linked)
    }

    func aggregateSnapshot(at url: URL) throws -> FileSnapshot {
        try FoundationReadOnlyFileSystem().aggregateSnapshot(at: url)
    }

    func children(of directory: URL) throws -> [URL] {
        try FoundationReadOnlyFileSystem().children(of: directory)
    }
}
