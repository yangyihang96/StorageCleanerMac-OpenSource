import Foundation
import XCTest
import zlib
@testable import StorageCleanerMac

final class AppUpdateSecureZipTests: XCTestCase {
    func testAutomaticInstallerAcceptsOnlyDMGAndZIPPackageTypes() {
        XCTAssertTrue(OfficialApplicationUpdateInstaller.supportsAutomaticPackageType(.diskImage))
        XCTAssertTrue(OfficialApplicationUpdateInstaller.supportsAutomaticPackageType(.zipArchive))
        XCTAssertFalse(OfficialApplicationUpdateInstaller.supportsAutomaticPackageType(.application))
        XCTAssertFalse(OfficialApplicationUpdateInstaller.supportsAutomaticPackageType(.installerPackage))
    }

    func testSafeZipExtractsOneApplicationAndPreservesContainedSymlink() async throws {
        let root = temporaryDirectory(named: "SafeZip")
        let archive = root.appendingPathComponent("Example.zip")
        let extracted = root.appendingPathComponent("Extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try StoredZipFixture(entries: [
            .directory("Example.app/"),
            .directory("Example.app/Contents/"),
            .directory("Example.app/Contents/MacOS/"),
            .directory("Example.app/Contents/Resources/"),
            .file("Example.app/Contents/Info.plist", data: Data("plist".utf8)),
            .executable("Example.app/Contents/MacOS/Example", data: Data("binary".utf8)),
            .symbolicLink("Example.app/Contents/ResourcesLink", target: "Resources"),
        ]).write(to: archive)

        let extractor = SecureZipArchiveExtractor()
        let manifest = try extractor.manifest(at: archive)
        XCTAssertEqual(manifest.count, 7)
        XCTAssertEqual(
            manifest.first { $0.relativePath.hasSuffix("ResourcesLink") }?.symbolicLinkTarget,
            "Resources"
        )

        try await extractor.extract(archiveURL: archive, to: extracted)

        let executable = extracted.appendingPathComponent(
            "Example.app/Contents/MacOS/Example"
        )
        let link = extracted.appendingPathComponent("Example.app/Contents/ResourcesLink")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            "Resources"
        )
        XCTAssertEqual(
            try OfficialApplicationUpdateInstaller.applicationBundleCandidates(in: [extracted])
                .map(\.lastPathComponent),
            ["Example.app"]
        )
    }

    func testZipCandidateDiscoveryReportsMultipleApplications() async throws {
        let root = temporaryDirectory(named: "MultipleAppsZip")
        let archive = root.appendingPathComponent("Multiple.zip")
        let extracted = root.appendingPathComponent("Extracted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try StoredZipFixture(entries: [
            .directory("First.app/"),
            .file("First.app/Contents.txt", data: Data("first".utf8)),
            .directory("Second.app/"),
            .file("Second.app/Contents.txt", data: Data("second".utf8)),
        ]).write(to: archive)
        try await SecureZipArchiveExtractor().extract(archiveURL: archive, to: extracted)

        XCTAssertEqual(
            try OfficialApplicationUpdateInstaller.applicationBundleCandidates(in: [extracted])
                .map(\.lastPathComponent).sorted(),
            ["First.app", "Second.app"]
        )
    }

    func testZipManifestRejectsTraversalDuplicateLocalMismatchAndSymlinkParent() throws {
        let root = temporaryDirectory(named: "RejectedZip")
        defer { try? FileManager.default.removeItem(at: root) }
        let extractor = SecureZipArchiveExtractor()

        let traversal = root.appendingPathComponent("Traversal.zip")
        try StoredZipFixture(entries: [
            .file("../escape", data: Data("bad".utf8)),
        ]).write(to: traversal)
        XCTAssertThrowsError(try extractor.manifest(at: traversal)) { error in
            guard case .invalidArchivePath = error as? PackageValidationError else {
                return XCTFail("Expected invalid archive path, got \(error)")
            }
        }

        let duplicate = root.appendingPathComponent("Duplicate.zip")
        try StoredZipFixture(entries: [
            .file("Example.app/Readme", data: Data("one".utf8)),
            .file("example.app/readme", data: Data("two".utf8)),
        ]).write(to: duplicate)
        XCTAssertThrowsError(try extractor.manifest(at: duplicate)) { error in
            guard case .duplicatePath = error as? SecureZipArchiveError else {
                return XCTFail("Expected duplicate path, got \(error)")
            }
        }

        let mismatch = root.appendingPathComponent("Mismatch.zip")
        try StoredZipFixture(entries: [
            .file(
                "Example.app/Contents/Info.plist",
                data: Data("plist".utf8),
                localName: "Example.app/Contents/Other.plist"
            ),
        ]).write(to: mismatch)
        XCTAssertThrowsError(try extractor.manifest(at: mismatch)) { error in
            guard case .localHeaderMismatch = error as? SecureZipArchiveError else {
                return XCTFail("Expected local header mismatch, got \(error)")
            }
        }

        let symlinkParent = root.appendingPathComponent("SymlinkParent.zip")
        try StoredZipFixture(entries: [
            .symbolicLink("Example.app/Contents/Link", target: "Resources"),
            .file("Example.app/Contents/Link/payload", data: Data("bad".utf8)),
        ]).write(to: symlinkParent)
        XCTAssertThrowsError(try extractor.manifest(at: symlinkParent)) { error in
            guard case .pathTypeConflict = error as? SecureZipArchiveError else {
                return XCTFail("Expected path type conflict, got \(error)")
            }
        }
    }

    func testBundleVerifierChecksBundleTeamAndStrictlyNewerVersionForZipCandidate() throws {
        let root = temporaryDirectory(named: "ZipIdentity")
        let candidate = root.appendingPathComponent("Example.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var installed = AppUpdateTestFixtures.application(
            bundleIdentifier: "com.example.app",
            path: "/Applications/Example.app",
            version: "1.0",
            build: "100",
            availableVersion: "2.0",
            signingTeamIdentifier: "TEAM123",
            provider: .officialWebsite,
            status: .automaticallyUpdatable,
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false
        )
        let source = OfficialUpdateSource(
            applicationIdentity: installed.identity,
            providerType: .officialManifest,
            developerName: "Example Developer",
            homepageURL: URL(string: "https://example.com"),
            updatePageURL: URL(string: "https://example.com/download"),
            releaseFeedURL: URL(string: "https://example.com/releases.json"),
            directDownloadURL: URL(string: "https://downloads.example.com/Example.zip"),
            allowedHosts: ["example.com", "downloads.example.com"],
            expectedBundleIdentifier: installed.bundleIdentifier,
            expectedTeamIdentifier: "TEAM123",
            expectedDesignatedRequirement: nil,
            verificationMethod: .signedRegistry,
            trustLevel: .registryVerified,
            lastVerifiedAt: AppUpdateTestFixtures.scanDate,
            capability: .automatic,
            expectedPackageExtensions: ["zip"],
            officialGitHubRepository: nil
        )
        installed.officialSource = source

        try writeApplication(
            at: candidate,
            bundleIdentifier: "com.example.app",
            version: "2.0",
            build: "200"
        )
        let matchingVerifier = BundleIdentityVerifier(signatureVerification: { _ in
            Self.signature(team: "TEAM123")
        })
        XCTAssertEqual(
            try matchingVerifier.verifyReplacement(
                at: candidate,
                for: installed,
                source: source
            ).candidateVersion,
            ApplicationVersion(marketing: "2.0", build: "200")
        )

        let wrongTeamVerifier = BundleIdentityVerifier(signatureVerification: { _ in
            Self.signature(team: "OTHERTEAM")
        })
        XCTAssertThrowsError(
            try wrongTeamVerifier.verifyReplacement(
                at: candidate,
                for: installed,
                source: source
            )
        ) { error in
            guard case .teamIdentifierChanged = error as? BundleIdentityValidationIssue else {
                return XCTFail("Expected team mismatch, got \(error)")
            }
        }

        try writeApplication(
            at: candidate,
            bundleIdentifier: "com.example.other",
            version: "2.0",
            build: "200"
        )
        XCTAssertThrowsError(
            try matchingVerifier.verifyReplacement(
                at: candidate,
                for: installed,
                source: source
            )
        ) { error in
            guard case .bundleIdentifierChanged = error as? BundleIdentityValidationIssue else {
                return XCTFail("Expected bundle mismatch, got \(error)")
            }
        }

        try writeApplication(
            at: candidate,
            bundleIdentifier: "com.example.app",
            version: "1.0",
            build: "100"
        )
        XCTAssertThrowsError(
            try matchingVerifier.verifyReplacement(
                at: candidate,
                for: installed,
                source: source
            )
        ) { error in
            guard case .versionNotNewer = error as? BundleIdentityValidationIssue else {
                return XCTFail("Expected non-newer version rejection, got \(error)")
            }
        }
    }

    private func temporaryDirectory(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeApplication(
        at url: URL,
        bundleIdentifier: String,
        version: String,
        build: String
    ) throws {
        let executableDirectory = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executableDirectory,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleExecutable": "Example",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .binary,
            options: 0
        )
        try infoData.write(to: url.appendingPathComponent("Contents/Info.plist"))

        #if arch(arm64)
        let cpu: [UInt8] = [0x0C, 0x00, 0x00, 0x01]
        #elseif arch(x86_64)
        let cpu: [UInt8] = [0x07, 0x00, 0x00, 0x01]
        #else
        let cpu: [UInt8] = [0, 0, 0, 0]
        #endif
        let executable = executableDirectory.appendingPathComponent("Example")
        try Data([0xCF, 0xFA, 0xED, 0xFE] + cpu).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    }

    private static func signature(team: String) -> CodeSignatureVerificationResult {
        CodeSignatureVerificationResult(
            isValid: true,
            codeSigningIdentifier: "com.example.app",
            teamIdentifier: team,
            designatedRequirement: nil,
            certificateCommonNames: [],
            status: 0
        )
    }
}

private struct StoredZipFixture {
    struct Entry {
        let centralName: String
        let localName: String
        let data: Data
        let unixMode: UInt16

        static func directory(_ path: String) -> Self {
            Self(
                centralName: path,
                localName: path,
                data: Data(),
                unixMode: 0o040755
            )
        }

        static func file(_ path: String, data: Data, localName: String? = nil) -> Self {
            Self(
                centralName: path,
                localName: localName ?? path,
                data: data,
                unixMode: 0o100644
            )
        }

        static func executable(_ path: String, data: Data) -> Self {
            Self(
                centralName: path,
                localName: path,
                data: data,
                unixMode: 0o100755
            )
        }

        static func symbolicLink(_ path: String, target: String) -> Self {
            Self(
                centralName: path,
                localName: path,
                data: Data(target.utf8),
                unixMode: 0o120777
            )
        }
    }

    let entries: [Entry]

    func write(to url: URL) throws {
        var archive = Data()
        var centralRecords = [(entry: Entry, offset: UInt32, checksum: UInt32)]()
        for entry in entries {
            let offset = UInt32(archive.count)
            let localName = Data(entry.localName.utf8)
            let checksum = Self.checksum(entry.data)
            archive.appendLE(UInt32(0x0403_4B50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(checksum)
            archive.appendLE(UInt32(entry.data.count))
            archive.appendLE(UInt32(entry.data.count))
            archive.appendLE(UInt16(localName.count))
            archive.appendLE(UInt16(0))
            archive.append(localName)
            archive.append(entry.data)
            centralRecords.append((entry, offset, checksum))
        }

        let centralOffset = UInt32(archive.count)
        for record in centralRecords {
            let name = Data(record.entry.centralName.utf8)
            archive.appendLE(UInt32(0x0201_4B50))
            archive.appendLE(UInt16(0x0314))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(record.checksum)
            archive.appendLE(UInt32(record.entry.data.count))
            archive.appendLE(UInt32(record.entry.data.count))
            archive.appendLE(UInt16(name.count))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt32(record.entry.unixMode) << 16)
            archive.appendLE(record.offset)
            archive.append(name)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendLE(UInt32(0x0605_4B50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(centralSize)
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        try archive.write(to: url)
    }

    private static func checksum(_ data: Data) -> UInt32 {
        let value = data.withUnsafeBytes { buffer -> uLong in
            guard let base = buffer.bindMemory(to: Bytef.self).baseAddress else {
                return crc32(0, nil, 0)
            }
            return crc32(crc32(0, nil, 0), base, uInt(buffer.count))
        }
        return UInt32(truncatingIfNeeded: value)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
