import Foundation
import XCTest
@testable import StorageCleanerMac

// Shared by the new performance/security tests and the existing command-shape
// test. Deliberately available in Release test builds, without a DEBUG guard.
enum AppUpdatePerformanceTestSupport {
    static let idle = ApplicationRunningStateSnapshot(bundleIdentifiers: [], normalizedBundlePaths: [])

    static func bundle(
        in root: URL,
        name: String = "Example",
        identifier: String = "com.example.example",
        version: String = "1.0"
    ) throws -> URL {
        let url = root.appendingPathComponent(name + ".app", isDirectory: true)
        for path in ["Contents/MacOS", "Contents/Resources", "Contents/_CodeSignature"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try writeInfo(at: url, identifier: identifier, version: version)
        try Data("executable-a".utf8).write(to: url.appendingPathComponent("Contents/MacOS/Example"))
        try Data("resource-a".utf8).write(to: url.appendingPathComponent("Contents/Resources/payload"))
        try Data("signature-a".utf8).write(to: url.appendingPathComponent("Contents/_CodeSignature/CodeResources"))
        return url
    }

    static func writeInfo(at url: URL, identifier: String = "com.example.example", version: String = "1.0", extra: String = "a") throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleName": "Example",
            "CFBundleShortVersionString": version, "CFBundleVersion": "100",
            "CFBundleExecutable": "Example", "FixtureRevision": extra,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    static func signature(for application: InstalledApplication, valid: Bool = true) -> CodeSignatureVerificationResult {
        CodeSignatureVerificationResult(
            isValid: valid, codeSigningIdentifier: application.codeSigningIdentifier,
            teamIdentifier: application.signingTeamIdentifier, designatedRequirement: nil,
            certificateCommonNames: [], status: valid ? 0 : -1
        )
    }

    static func fingerprints(mount: String = "test-volume|mount-1") -> FileSystemApplicationBundleFingerprintReader {
        FileSystemApplicationBundleFingerprintReader(mountIdentityReader: { _ in mount })
    }
}

actor AppUpdateCountingSignatureInspector: ApplicationCodeSignatureInspecting {
    private(set) var paths = [URL]()
    private var valid = true
    private var team = "TEAM123"
    private var requireOriginalResource = false
    func setValid(_ value: Bool) { valid = value }
    func setTeam(_ value: String) { team = value }
    func requireUnchangedResource() { requireOriginalResource = true }
    func inspectSignature(at applicationURL: URL) async -> ApplicationCodeSignatureMetadata {
        paths.append(applicationURL)
        let data = try? Data(contentsOf: applicationURL.appendingPathComponent("Contents/Info.plist"))
        let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let resourceValid = !requireOriginalResource
            || (try? Data(contentsOf: applicationURL.appendingPathComponent("Contents/Resources/payload"))) == Data("resource-a".utf8)
        return ApplicationCodeSignatureMetadata(
            signingTeamIdentifier: team, codeSigningIdentifier: plist?["CFBundleIdentifier"] as? String,
            isValid: valid && resourceValid
        )
    }
}

actor AppUpdateCountingMetadataReader: ApplicationMetadataReading {
    private let reader: ApplicationMetadataReader
    private(set) var count = 0
    init(inspector: AppUpdateCountingSignatureInspector) {
        reader = ApplicationMetadataReader(signatureInspector: inspector)
    }
    func read(applicationURL: URL, runningState: ApplicationRunningStateSnapshot, scanDate: Date) async -> InstalledApplication? {
        count += 1
        return await reader.read(applicationURL: applicationURL, runningState: runningState, scanDate: scanDate)
    }
}

struct AppUpdateFreshTestRechecker: InstalledApplicationRechecking {
    let operation: @Sendable (URL) async throws -> InstalledApplicationRecheckSnapshot?
    func snapshot(at applicationURL: URL) async throws -> InstalledApplicationRecheckSnapshot? {
        try await operation(applicationURL)
    }
}

final class AppUpdateFreshCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths = [URL]()
    private var recordedTokens = [String]()
    private var commandCount = 0
    var paths: [URL] { lock.withLock { recordedPaths } }
    var tokens: [String] { lock.withLock { recordedTokens } }
    var commands: Int { lock.withLock { commandCount } }
    func record(path: URL) { lock.withLock { recordedPaths.append(path) } }
    func record(token: String) { lock.withLock { recordedTokens.append(token) } }
    func command() { lock.withLock { commandCount += 1 } }
}
