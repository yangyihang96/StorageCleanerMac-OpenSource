import Foundation
import XCTest
@testable import StorageCleanerMac

final class StartupApplicationSigningIdentityTests: XCTestCase {
    func testReaderRunsOnlyFixedCodesignAndParsesBoundedIdentity() async throws {
        let fixture = try applicationFixture(named: "Signed")
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let runner = RecordingSigningProcessRunner(outcomes: [
            .result(.init(
                standardOutput: "",
                standardError: "Signed.app: valid on disk",
                terminationStatus: 0
            )),
            .result(.init(
                standardOutput: "",
                standardError: Self.validCodesignOutput,
                terminationStatus: 0
            )),
        ])
        let reader = StartupApplicationSigningIdentityReader(
            runner: runner,
            timeout: 0.4,
            maximumOutputBytes: 8 * 1_024
        )

        let identity = await reader.identity(
            at: fixture.bundleURL,
            executableURL: fixture.executableURL
        )
        let calls = await runner.recordedCalls()

        XCTAssertEqual(identity?.teamIdentifier, "TEAM123456")
        XCTAssertEqual(identity?.codeSigningIdentifier, "com.example.signed")
        XCTAssertEqual(
            identity?.designatedRequirement,
            "identifier \"com.example.signed\" and anchor apple generic"
        )
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].executableURL.path, "/usr/bin/codesign")
        // D42 (confirmed 2026-10-07): codesign's default verification plus an
        // Apple-issued certificate chain; no `--strict` (its sideband check
        // rejects Finder information left on an intact, signed bundle).
        XCTAssertEqual(calls[0].arguments, [
            "--verify", "--verbose=1", "-R", "=anchor apple generic", fixture.bundleURL.path,
        ])
        XCTAssertFalse(calls[0].arguments.contains { $0.hasPrefix("--strict") || $0 == "--no-strict" })
        XCTAssertEqual(calls[1].arguments, [
            "--display", "--verbose=1", "--requirements", "-", fixture.bundleURL.path,
        ])
        XCTAssertEqual(calls[0].timeout, 0.4, accuracy: 0.001)
        XCTAssertEqual(calls[1].timeout, 0.4, accuracy: 0.001)
    }

    /// Live test 2026-10-06: Google Chrome's updater leaves Finder information
    /// on files in its signed bundle. `codesign --verify --strict` rejects it
    /// as "detritus" although the signature is intact, so every Chrome record
    /// was routed to the browser. The identity still comes through when only
    /// the strict sideband check objects.
    func testFinderInfoRejectedOnlyByTheStrictCheckStillYieldsAnIdentity() async throws {
        let fixture = try applicationFixture(named: "Detritus")
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let codesign = SimulatedCodesign(strictFailsWithDetritus: true)
        let reader = StartupApplicationSigningIdentityReader(runner: codesign)

        let identity = await reader.identity(at: fixture.bundleURL, executableURL: fixture.executableURL)

        XCTAssertEqual(identity?.teamIdentifier, "TEAM123456")
        XCTAssertEqual(identity?.codeSigningIdentifier, "com.example.signed")
        XCTAssertNotNil(identity?.designatedRequirement)
        let calls = await codesign.recordedArguments()
        XCTAssertEqual(calls.count, 2)
    }

    /// Integrity and the Apple certificate chain are still required: a bundle
    /// whose sealed contents changed, or one signed ad hoc or with a
    /// self-made certificate (which can claim any Team ID), stays unknown.
    func testModifiedOrNonAppleSignedBundlesStayUnknown() async throws {
        let fixture = try applicationFixture(named: "Rejected")
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }

        let modified = SimulatedCodesign(integrityIntact: false)
        let modifiedIdentity = await StartupApplicationSigningIdentityReader(runner: modified)
            .identity(at: fixture.bundleURL, executableURL: fixture.executableURL)
        XCTAssertNil(modifiedIdentity)
        let modifiedCalls = await modified.recordedArguments()
        XCTAssertEqual(modifiedCalls.count, 1, "Nothing is read from a bundle that failed verification")

        let selfSigned = SimulatedCodesign(appleAnchored: false)
        let selfSignedIdentity = await StartupApplicationSigningIdentityReader(runner: selfSigned)
            .identity(at: fixture.bundleURL, executableURL: fixture.executableURL)
        XCTAssertNil(selfSignedIdentity)
        let selfSignedCalls = await selfSigned.recordedArguments()
        XCTAssertEqual(selfSignedCalls.count, 1)
    }

    /// The same behaviour with the real `/usr/bin/codesign`, on throwaway
    /// copies of an Apple-signed app from the active Xcode (apps on the sealed
    /// system volume do not validate once copied). No installed app is read
    /// for its identity or changed.
    func testRealCodesignAcceptsFinderInfoButRejectsModifiedAndAdHocCopies() async throws {
        let source = try appleSignedFixtureSource()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StartupSigningIdentity-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StartupItemsDomain.CancellableStartupProcessRunner(outputByteLimit: 64 * 1_024)
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")

        let clean = root.appendingPathComponent("Clean.app", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: clean)
        let cleanCheck = try await runner.run(
            executableURL: codesign, arguments: ["--verify", clean.path], timeout: 30
        )
        guard cleanCheck.terminationStatus == 0 else {
            throw XCTSkip("The Apple-signed fixture does not validate once copied: \(cleanCheck.combinedOutput)")
        }

        let detritus = root.appendingPathComponent("Detritus.app", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: detritus)
        let detritusExecutable = try XCTUnwrap(Bundle(url: detritus)?.executableURL)
        try addFinderInfo(to: detritus)
        try addFinderInfo(to: detritusExecutable)
        // The root cause, with the arguments the reader used before.
        let strict = try await runner.run(
            executableURL: codesign, arguments: ["--verify", "--strict", "--verbose=1", detritus.path], timeout: 30
        )
        XCTAssertNotEqual(strict.terminationStatus, 0)
        XCTAssertTrue(strict.combinedOutput.contains("detritus"), strict.combinedOutput)

        let modified = root.appendingPathComponent("Modified.app", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: modified)
        let sealedResource = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: modified.appendingPathComponent("Contents/Resources", isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey]
        ).sorted { $0.path < $1.path }.first {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        })
        let handle = try FileHandle(forWritingTo: sealedResource)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x78]))
        try handle.close()

        let adHoc = root.appendingPathComponent("AdHoc.app", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: adHoc)
        // Ad hoc signing uses no certificate or keychain item.
        let resigned = try await runner.run(
            executableURL: codesign, arguments: ["--sign", "-", "--force", adHoc.path], timeout: 30
        )
        XCTAssertEqual(resigned.terminationStatus, 0, resigned.combinedOutput)

        let reader = StartupApplicationSigningIdentityReader(timeout: 30)
        let detritusIdentity = await reader.identity(at: detritus, executableURL: detritusExecutable)
        XCTAssertNotNil(detritusIdentity?.teamIdentifier)
        XCTAssertEqual(detritusIdentity?.codeSigningIdentifier, Bundle(url: source)?.bundleIdentifier)
        XCTAssertTrue(detritusIdentity?.designatedRequirement?.contains("anchor apple") == true)
        let modifiedIdentity = await reader.identity(
            at: modified, executableURL: Bundle(url: modified)?.executableURL
        )
        XCTAssertNil(modifiedIdentity)
        let adHocIdentity = await reader.identity(at: adHoc, executableURL: Bundle(url: adHoc)?.executableURL)
        XCTAssertNil(adHocIdentity)

        // Security.framework call sites validate with kSecCSStrictValidate but
        // not kSecCSRestrictSidebandData, so the same Finder information does
        // not affect them (kept unchanged; see the r2-live-fixes-1 handoff).
        let verified = try CodeSignatureVerifier().verifyCode(at: detritus)
        XCTAssertTrue(verified.isValid)
        XCTAssertNotNil(verified.teamIdentifier, "Apple-anchored, so the Team ID is trusted")
        let metadata = await SecurityFrameworkApplicationCodeSignatureInspector().inspectSignature(at: detritus)
        XCTAssertTrue(metadata.isValid)
        XCTAssertNotNil(metadata.signingTeamIdentifier)
        XCTAssertThrowsError(try CodeSignatureVerifier().verifyCode(at: modified))
    }

    func testUnsignedTimeoutAndOversizedOutputStayUnknown() async throws {
        let fixture = try applicationFixture(named: "Unknown")
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }

        let unsigned = StartupApplicationSigningIdentityReader(
            runner: RecordingSigningProcessRunner(outcomes: [
                .result(.init(
                    standardOutput: "",
                    standardError: "code object is not signed at all",
                    terminationStatus: 1
                )),
            ])
        )
        let unsignedIdentity = await unsigned.identity(
            at: fixture.bundleURL,
            executableURL: fixture.executableURL
        )
        XCTAssertNil(unsignedIdentity)

        let timedOut = StartupApplicationSigningIdentityReader(
            runner: RecordingSigningProcessRunner(outcomes: [.failure])
        )
        let timedOutIdentity = await timedOut.identity(
            at: fixture.bundleURL,
            executableURL: fixture.executableURL
        )
        XCTAssertNil(timedOutIdentity)

        let oversized = StartupApplicationSigningIdentityReader(
            runner: RecordingSigningProcessRunner(outcomes: [
                .result(.init(
                    standardOutput: String(repeating: "x", count: 128),
                    standardError: Self.validCodesignOutput,
                    terminationStatus: 0
                )),
            ]),
            maximumOutputBytes: 64
        )
        let oversizedIdentity = await oversized.identity(
            at: fixture.bundleURL,
            executableURL: fixture.executableURL
        )
        XCTAssertNil(oversizedIdentity)
    }

    func testCacheUsesBundlePathAndInvalidatesWhenExecutableChanges() async throws {
        let first = try applicationFixture(named: "First")
        let second = try applicationFixture(named: "Second")
        defer { try? FileManager.default.removeItem(at: first.bundleURL) }
        defer { try? FileManager.default.removeItem(at: second.bundleURL) }
        let runner = RecordingSigningProcessRunner(outcomes: Array(repeating: .result(.init(
            standardOutput: "",
            standardError: Self.validCodesignOutput,
            terminationStatus: 0
        )), count: 6))
        let reader = StartupApplicationSigningIdentityReader(runner: runner)

        _ = await reader.identity(at: first.bundleURL, executableURL: first.executableURL)
        _ = await reader.identity(at: first.bundleURL, executableURL: first.executableURL)
        let initialCallCount = await runner.recordedCallCount()
        XCTAssertEqual(initialCallCount, 2)

        try Data("changed executable bytes".utf8).write(to: first.executableURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: first.executableURL.path
        )
        _ = await reader.identity(at: first.bundleURL, executableURL: first.executableURL)
        let invalidatedCallCount = await runner.recordedCallCount()
        XCTAssertEqual(invalidatedCallCount, 4)

        _ = await reader.identity(at: second.bundleURL, executableURL: second.executableURL)
        let movedPathCallCount = await runner.recordedCallCount()
        XCTAssertEqual(movedPathCallCount, 6)
    }

    func testIndexReadsOnlyApplicationsReferencedByStartupEvidence() async throws {
        let referenced = try applicationFixture(named: "Referenced")
        let unrelated = try applicationFixture(named: "Unrelated")
        defer { try? FileManager.default.removeItem(at: referenced.bundleURL) }
        defer { try? FileManager.default.removeItem(at: unrelated.bundleURL) }
        let reader = RecordingSigningIdentityReader(identity: StartupApplicationSigningIdentity(
            teamIdentifier: "TEAM123456",
            codeSigningIdentifier: "com.example.parent",
            designatedRequirement: "identifier com.example.parent"
        ))
        let index = InstalledApplicationIndex(applications: [
            installedApplication(
                bundleIdentifier: "com.example.parent",
                fixture: referenced
            ),
            installedApplication(
                bundleIdentifier: "com.example.unrelated",
                fixture: unrelated
            ),
        ])
        var candidate = fixtureCandidate()
        candidate.attribution = StartupItemsDomain.Attribution(
            applicationBundleIdentifier: "com.example.parent",
            applicationURL: nil,
            applicationName: nil,
            developerName: nil,
            teamIdentifier: "TEAM123456",
            designatedRequirement: nil,
            evidence: [
                .init(
                    kind: .backgroundTaskManagement,
                    value: "com.example.parent",
                    confidence: .verified
                ),
            ]
        )

        let enriched = await index.enrichingSigningIdentities(
            referencedBy: [candidate],
            reader: reader
        )
        let paths = await reader.recordedPaths()

        XCTAssertEqual(paths, [referenced.bundleURL.path])
        XCTAssertEqual(enriched.applications[0].teamIdentifier, "TEAM123456")
        XCTAssertEqual(enriched.applications[0].codeSigningIdentifier, "com.example.parent")
        XCTAssertNil(enriched.applications[1].teamIdentifier)
    }

    func testIndexBoundsConcurrentSigningIdentityReads() async throws {
        var fixtures = [ApplicationFixture]()
        defer {
            for fixture in fixtures {
                try? FileManager.default.removeItem(at: fixture.bundleURL)
            }
        }

        var applications = [StartupInstalledApplication]()
        var candidates = [StartupItemsDomain.Candidate]()
        for index in 0..<12 {
            let fixture = try applicationFixture(named: "Concurrent-\(index)")
            fixtures.append(fixture)
            let bundleIdentifier = "com.example.concurrent.\(index)"
            applications.append(installedApplication(
                bundleIdentifier: bundleIdentifier,
                fixture: fixture
            ))
            var candidate = fixtureCandidate()
            candidate.attribution = StartupItemsDomain.Attribution(
                applicationBundleIdentifier: bundleIdentifier,
                applicationURL: nil,
                applicationName: nil,
                developerName: nil,
                teamIdentifier: nil,
                designatedRequirement: nil,
                evidence: []
            )
            candidates.append(candidate)
        }

        let reader = ConcurrencyTrackingSigningIdentityReader()
        let enriched = await InstalledApplicationIndex(applications: applications)
            .enrichingSigningIdentities(referencedBy: candidates, reader: reader)
        let peak = await reader.peakActiveReads()

        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertTrue(enriched.applications.allSatisfy { $0.teamIdentifier == "TEAM123456" })
    }

    func testResolverRequiresTeamAndSigningIdentifierToDisambiguateCopies() {
        var candidate = fixtureCandidate()
        candidate.attribution = StartupItemsDomain.Attribution(
            applicationBundleIdentifier: "com.example.parent",
            applicationURL: nil,
            applicationName: "Background Helper",
            developerName: nil,
            teamIdentifier: "RIGHTTEAM",
            designatedRequirement: nil,
            evidence: [
                .init(
                    kind: .backgroundTaskManagement,
                    value: "com.example.parent",
                    confidence: .verified
                ),
            ]
        )
        let correctURL = URL(fileURLWithPath: "/Applications/Correct.app")
        let wrongURL = URL(fileURLWithPath: "/Applications/Wrong.app")
        let matching = StartupInstalledApplication(
            bundleIdentifier: "com.example.parent",
            bundleURL: correctURL,
            executableURL: nil,
            displayName: "Correct",
            developerName: nil,
            teamIdentifier: "RIGHTTEAM",
            codeSigningIdentifier: "com.example.parent",
            designatedRequirement: nil
        )
        let wrongIdentifier = StartupInstalledApplication(
            bundleIdentifier: "com.example.parent",
            bundleURL: wrongURL,
            executableURL: nil,
            displayName: "Wrong",
            developerName: nil,
            teamIdentifier: "RIGHTTEAM",
            codeSigningIdentifier: "com.example.other",
            designatedRequirement: nil
        )

        let resolved = StartupAttributionResolver().resolve(
            candidate,
            using: InstalledApplicationIndex(applications: [wrongIdentifier, matching])
        )
        XCTAssertEqual(resolved.applicationURL, correctURL)

        let unresolved = StartupAttributionResolver().resolve(
            candidate,
            using: InstalledApplicationIndex(applications: [wrongIdentifier, wrongIdentifier])
        )
        XCTAssertNil(unresolved.applicationURL)
        XCTAssertNil(unresolved.attribution?.applicationURL)
        XCTAssertEqual(unresolved.attribution?.applicationName, "Background Helper")
    }

    private static let validCodesignOutput = """
    Executable=/Applications/Signed.app/Contents/MacOS/Signed
    Identifier=com.example.signed
    TeamIdentifier=TEAM123456
    designated => identifier "com.example.signed" and anchor apple generic
    """

    /// An Apple-signed app outside the sealed system volume, from the Xcode
    /// that runs the tests. Skips when none is installed.
    private func appleSignedFixtureSource() throws -> URL {
        var contentsFolders = [URL]()
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            contentsFolders.append(URL(fileURLWithPath: developer).deletingLastPathComponent())
        }
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let xcodes = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        contentsFolders += xcodes.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted().map {
            applications.appendingPathComponent($0).appendingPathComponent("Contents", isDirectory: true)
        }
        for folder in contentsFolders {
            let candidate = folder.appendingPathComponent("Applications/FileMerge.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("No Apple-signed FileMerge.app found in an installed Xcode")
    }

    /// The Finder information that `codesign --strict` calls detritus.
    private func addFinderInfo(to url: URL) throws {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x40
        let status = url.path.withCString { path in
            setxattr(path, "com.apple.FinderInfo", finderInfo, finderInfo.count, 0, 0)
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func applicationFixture(named name: String) throws -> ApplicationFixture {
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StartupSigningIdentity-\(name)-\(UUID().uuidString).app",
            isDirectory: true
        )
        let executableURL = bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture executable".utf8).write(to: executableURL)
        return ApplicationFixture(bundleURL: bundleURL, executableURL: executableURL)
    }

    private func installedApplication(
        bundleIdentifier: String,
        fixture: ApplicationFixture
    ) -> StartupInstalledApplication {
        StartupInstalledApplication(
            bundleIdentifier: bundleIdentifier,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL,
            displayName: fixture.bundleURL.deletingPathExtension().lastPathComponent,
            developerName: nil,
            teamIdentifier: nil,
            codeSigningIdentifier: nil,
            designatedRequirement: nil
        )
    }

    private func fixtureCandidate() -> StartupItemsDomain.Candidate {
        StartupItemsDomain.Candidate(
            id: "fixture",
            source: .backgroundTaskDiagnostic,
            kind: .appBackgroundTask,
            scope: .currentUser,
            name: "Background Helper",
            label: "com.example.helper",
            plistURL: nil,
            executableURL: nil,
            applicationURL: nil,
            configuration: nil,
            state: .unknown,
            attribution: nil,
            actionCapability: .readOnly,
            diagnosticEvidence: []
        )
    }
}

private struct ApplicationFixture {
    let bundleURL: URL
    let executableURL: URL
}

private actor RecordingSigningIdentityReader: StartupApplicationSigningIdentityReading {
    let identityValue: StartupApplicationSigningIdentity?
    private var paths = [String]()

    init(identity: StartupApplicationSigningIdentity?) {
        identityValue = identity
    }

    func identity(
        at bundleURL: URL,
        executableURL: URL?
    ) -> StartupApplicationSigningIdentity? {
        paths.append(bundleURL.path)
        return identityValue
    }

    func recordedPaths() -> [String] { paths }
}

private actor ConcurrencyTrackingSigningIdentityReader: StartupApplicationSigningIdentityReading {
    private var activeReads = 0
    private var maximumActiveReads = 0

    func identity(
        at bundleURL: URL,
        executableURL: URL?
    ) async -> StartupApplicationSigningIdentity? {
        activeReads += 1
        maximumActiveReads = max(maximumActiveReads, activeReads)
        defer { activeReads -= 1 }
        try? await Task.sleep(for: .milliseconds(20))
        return StartupApplicationSigningIdentity(
            teamIdentifier: "TEAM123456",
            codeSigningIdentifier: bundleURL.deletingPathExtension().lastPathComponent,
            designatedRequirement: nil
        )
    }

    func peakActiveReads() -> Int { maximumActiveReads }
}

private actor RecordingSigningProcessRunner: StartupItemsDomain.StartupProcessRunning {
    enum Outcome: Sendable {
        case result(StartupItemsDomain.StartupProcessResult)
        case failure
    }

    struct Call: Sendable {
        let executableURL: URL
        let arguments: [String]
        let timeout: TimeInterval
    }

    private var outcomes: [Outcome]
    private var calls = [Call]()

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> StartupItemsDomain.StartupProcessResult {
        calls.append(Call(executableURL: executableURL, arguments: arguments, timeout: timeout))
        guard !outcomes.isEmpty else { throw FixtureSigningError.failed }
        switch outcomes.removeFirst() {
        case let .result(result): return result
        case .failure: throw FixtureSigningError.failed
        }
    }

    func recordedCalls() -> [Call] { calls }
    func recordedCallCount() -> Int { calls.count }
}

private enum FixtureSigningError: Error {
    case failed
}

/// Answers like `/usr/bin/codesign` for one bundle: `--strict` rejects
/// Finder information as detritus, a changed sealed file fails every
/// verification, and a non-Apple certificate chain fails the explicit
/// `anchor apple generic` requirement with status 3.
private actor SimulatedCodesign: StartupItemsDomain.StartupProcessRunning {
    private let strictFailsWithDetritus: Bool
    private let integrityIntact: Bool
    private let appleAnchored: Bool
    private var arguments = [[String]]()

    init(strictFailsWithDetritus: Bool = false, integrityIntact: Bool = true, appleAnchored: Bool = true) {
        self.strictFailsWithDetritus = strictFailsWithDetritus
        self.integrityIntact = integrityIntact
        self.appleAnchored = appleAnchored
    }

    func run(
        executableURL _: URL,
        arguments: [String],
        timeout _: TimeInterval
    ) async throws -> StartupItemsDomain.StartupProcessResult {
        self.arguments.append(arguments)
        if arguments.first == "--display" {
            return .init(standardOutput: "", standardError: """
            Executable=/Applications/Signed.app/Contents/MacOS/Signed
            Identifier=com.example.signed
            TeamIdentifier=TEAM123456
            designated => identifier "com.example.signed" and anchor apple generic
            """, terminationStatus: 0)
        }
        guard integrityIntact else {
            return .init(standardOutput: "", standardError: "Signed.app: a sealed resource is missing or invalid",
                         terminationStatus: 1)
        }
        if strictFailsWithDetritus, arguments.contains(where: { $0.hasPrefix("--strict") }) {
            return .init(standardOutput: "",
                         standardError: "Signed.app: resource fork, Finder information, or similar detritus not allowed",
                         terminationStatus: 1)
        }
        if !appleAnchored,
           let index = arguments.firstIndex(of: "-R"),
           arguments.indices.contains(index + 1),
           arguments[index + 1] == "=anchor apple generic" {
            return .init(standardOutput: "", standardError: """
            Signed.app: valid on disk
            Signed.app: satisfies its Designated Requirement
            test-requirement: code failed to satisfy specified code requirement(s)
            """, terminationStatus: 3)
        }
        return .init(standardOutput: "", standardError: "Signed.app: valid on disk", terminationStatus: 0)
    }

    func recordedArguments() -> [[String]] { arguments }
}
