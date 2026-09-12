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
        XCTAssertEqual(calls[0].arguments, [
            "--verify", "--strict", "--verbose=1", fixture.bundleURL.path,
        ])
        XCTAssertEqual(calls[1].arguments, [
            "--display", "--verbose=1", "--requirements", "-", fixture.bundleURL.path,
        ])
        XCTAssertEqual(calls[0].timeout, 0.4, accuracy: 0.001)
        XCTAssertEqual(calls[1].timeout, 0.4, accuracy: 0.001)
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
