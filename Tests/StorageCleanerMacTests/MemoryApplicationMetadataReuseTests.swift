import AppKit
import Darwin
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MemoryApplicationMetadataReuseTests: XCTestCase {
    func testNameAndPathsAreReadOnceButBirthPolicyAndActiveStateAreReadEveryRound() {
        let app = MetadataApplication(pid: 630_001)
        defer { _ = RunningApplicationIdentityCache.identities(of: [MetadataApplication]()) }
        var birthReads = 0
        for round in 0..<3 {
            app.active = round == 2
            app.policy = round == 1 ? .accessory : .regular
            let identities = RunningApplicationIdentityCache.identities(of: [app], startTime: { _ in
                birthReads += 1
                return 1_000_000
            })
            XCTAssertEqual(identities.first?.1.name, "Display")
            XCTAssertEqual(identities.first?.1.isActive, round == 2)
            XCTAssertEqual(identities.first?.1.activationPolicy, round == 1 ? .accessory : .regular)
        }
        XCTAssertEqual(birthReads, 3)
        XCTAssertEqual(app.nameReads, 1)
        XCTAssertEqual(app.pathReads, 1)
        XCTAssertEqual(app.policyReads, 3)
        XCTAssertEqual(app.activeReads, 3)
    }

    func testUnknownBirthAndExitedOrReusedPIDReReadNamesAndPaths() {
        let app = MetadataApplication(pid: 630_002)
        defer { _ = RunningApplicationIdentityCache.identities(of: [MetadataApplication]()) }
        for _ in 0..<2 { _ = RunningApplicationIdentityCache.identities(of: [app], startTime: { _ in nil }) }
        XCTAssertEqual(app.nameReads, 2)
        for birth in [UInt64(1_000_000), 1_000_000, 2_000_000] {
            _ = RunningApplicationIdentityCache.identities(of: [app], startTime: { _ in birth })
        }
        XCTAssertEqual(app.nameReads, 4)
        _ = RunningApplicationIdentityCache.identities(of: [MetadataApplication]())
        _ = RunningApplicationIdentityCache.identities(of: [app], startTime: { _ in 2_000_000 })
        XCTAssertEqual(app.nameReads, 5)
        XCTAssertEqual(app.pathReads, 5)
    }

    func testIncompleteMetadataRetriesAfterRecoveryWithoutReReadingSuccessfulFields() {
        let app = MetadataApplication(pid: 630_003)
        app.metadataAvailable = false
        defer { _ = RunningApplicationIdentityCache.identities(of: [MetadataApplication]()) }
        let first = RunningApplicationIdentityCache.identities(of: [app], startTime: { _ in 1_000_000 })
        XCTAssertNil(first.first?.1.name)
        XCTAssertNil(first.first?.1.executablePath)
        app.metadataAvailable = true
        for _ in 0..<2 {
            let recovered = RunningApplicationIdentityCache.identities(of: [app], startTime: { _ in 1_000_000 })
            XCTAssertEqual(recovered.first?.1.name, "Display")
            XCTAssertEqual(recovered.first?.1.executablePath, "/Applications/Display.app/Contents/MacOS/Display")
        }
        XCTAssertEqual(app.nameReads, 2)
        XCTAssertEqual(app.pathReads, 2)
    }

    func testQuitValidationRequiresTheFreshTargetBirthEvenWhenDisplayMetadataWasCached() throws {
        let app = MetadataApplication(pid: 630_004)
        defer { _ = RunningApplicationIdentityCache.identities(of: [MetadataApplication]()) }
        let displayed = try XCTUnwrap(RunningApplicationIdentityCache.identities(
            of: [app], startTime: { _ in 1_000_000 }).first?.1)
        let process = MemoryProcess(id: app.processIdentifier, name: displayed.name ?? "Display",
                                    path: displayed.executablePath ?? "", iconPath: displayed.bundlePath ?? "",
                                    bundlePath: displayed.bundlePath, residentBytes: 1_000, percent: 1,
                                    canQuit: true, isActive: false, bundleIdentifier: displayed.bundleIdentifier,
                                    launchDate: displayed.launchDate, userIdentifier: 123)
        let fresh = MemoryRunningApplicationIdentity(
            processIdentifier: app.processIdentifier, bundlePath: displayed.bundlePath,
            executablePath: displayed.executablePath, activationPolicy: .regular,
            bundleIdentifier: displayed.bundleIdentifier, launchDate: Date(timeIntervalSince1970: 2),
            userIdentifier: 123)
        XCTAssertThrowsError(try MemoryOptimizerService.validateQuitTarget(
            process, against: fresh, currentProcessIdentifier: 999)) { error in
            guard case MemoryOptimizerError.processIdentityChanged = error else {
                return XCTFail("Expected processIdentityChanged, got \(error)")
            }
        }
    }
}

private final class MetadataApplication: RunningApplicationIdentitySource {
    let processIdentifier: pid_t
    var metadataAvailable = true
    var active = false
    var policy: NSApplication.ActivationPolicy = .regular
    var nameReads = 0
    var pathReads = 0
    var policyReads = 0
    var activeReads = 0

    init(pid: pid_t) { processIdentifier = pid }
    var localizedName: String? { nameReads += 1; return metadataAvailable ? "Display" : nil }
    var bundleIdentifier: String? { metadataAvailable ? "example.display" : nil }
    var bundleURL: URL? { metadataAvailable ? URL(fileURLWithPath: "/Applications/Display.app") : nil }
    var executableURL: URL? {
        pathReads += 1
        return metadataAvailable ? URL(fileURLWithPath: "/Applications/Display.app/Contents/MacOS/Display") : nil
    }
    var launchDate: Date? { metadataAvailable ? Date(timeIntervalSince1970: 1) : nil }
    var activationPolicy: NSApplication.ActivationPolicy { policyReads += 1; return policy }
    var isActive: Bool { activeReads += 1; return active }
}
